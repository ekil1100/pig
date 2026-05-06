const std = @import("std");

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Request = struct {
    method: []const u8,
    url: []const u8,
    headers: []Header,
    body: []const u8,
    timeout_ms: u64 = 30000,

    pub fn deinit(self: *Request, allocator: std.mem.Allocator) void {
        allocator.free(self.method);
        allocator.free(self.url);
        for (self.headers) |header| {
            allocator.free(header.name);
            allocator.free(header.value);
        }
        allocator.free(self.headers);
        allocator.free(self.body);
        self.* = undefined;
    }

    pub fn headerValue(self: Request, name: []const u8) ?[]const u8 {
        for (self.headers) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
        }
        return null;
    }
};

pub const ResponseStreamError = error{ReadFailed};

pub const ResponseStream = struct {
    ptr: *anyopaque,
    next_chunk: *const fn (ptr: *anyopaque, buffer: []u8) ResponseStreamError!?[]const u8,
    deinit_fn: *const fn (ptr: *anyopaque) void = noopDeinit,

    pub fn nextChunk(self: ResponseStream, buffer: []u8) ResponseStreamError!?[]const u8 {
        return self.next_chunk(self.ptr, buffer);
    }

    pub fn deinit(self: ResponseStream) void {
        self.deinit_fn(self.ptr);
    }

    fn noopDeinit(ptr: *anyopaque) void {
        _ = ptr;
    }
};

pub const TransportError = error{ OutOfMemory, UnsupportedTransport, RequestFailed };

pub const Transport = struct {
    ptr: *anyopaque,
    send_streaming: *const fn (ptr: *anyopaque, request: Request) TransportError!ResponseStream,

    pub fn sendStreaming(self: Transport, request: Request) TransportError!ResponseStream {
        return self.send_streaming(self.ptr, request);
    }
};

pub const RecordedStream = struct {
    chunks: []const []const u8,
    index: usize = 0,

    pub fn stream(self: *RecordedStream) ResponseStream {
        return .{ .ptr = self, .next_chunk = nextChunkImpl };
    }

    pub fn nextChunk(self: *RecordedStream, buffer: []u8) ?[]const u8 {
        _ = buffer;
        if (self.index >= self.chunks.len) return null;
        defer self.index += 1;
        return self.chunks[self.index];
    }

    fn nextChunkImpl(ptr: *anyopaque, buffer: []u8) ResponseStreamError!?[]const u8 {
        const self: *RecordedStream = @ptrCast(@alignCast(ptr));
        return self.nextChunk(buffer);
    }
};

pub const UnsupportedTransport = struct {
    pub fn transport(self: *UnsupportedTransport) Transport {
        return .{ .ptr = self, .send_streaming = sendStreaming };
    }

    fn sendStreaming(ptr: *anyopaque, request: Request) TransportError!ResponseStream {
        _ = ptr;
        _ = request;
        return error.UnsupportedTransport;
    }
};

pub const HttpTransport = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn transport(self: *HttpTransport) Transport {
        return .{ .ptr = self, .send_streaming = sendStreaming };
    }

    fn sendStreaming(ptr: *anyopaque, request: Request) TransportError!ResponseStream {
        const self: *HttpTransport = @ptrCast(@alignCast(ptr));
        var state = try HttpStreamState.init(self.allocator, self.io, request);
        return state.stream();
    }
};

const HttpStreamState = struct {
    allocator: std.mem.Allocator,
    client: std.http.Client,
    request: std.http.Client.Request = undefined,
    response: std.http.Client.Response = undefined,
    request_initialized: bool = false,
    extra_headers: []std.http.Header = &.{},
    transfer_buffer: [8192]u8 = undefined,
    redirect_buffer: [8192]u8 = undefined,
    reader: ?*std.Io.Reader = null,

    fn init(allocator: std.mem.Allocator, io: std.Io, request: Request) TransportError!*HttpStreamState {
        const state = allocator.create(HttpStreamState) catch return error.OutOfMemory;
        state.* = .{
            .allocator = allocator,
            .client = .{ .allocator = allocator, .io = io },
        };
        errdefer {
            state.cleanup();
            allocator.destroy(state);
        }

        const uri = std.Uri.parse(request.url) catch return error.RequestFailed;
        const method = parseMethod(request.method) orelse return error.RequestFailed;
        state.extra_headers = allocator.alloc(std.http.Header, request.headers.len) catch return error.OutOfMemory;
        for (request.headers, 0..) |header, i| {
            state.extra_headers[i] = .{ .name = header.name, .value = header.value };
        }

        state.request = state.client.request(method, uri, .{
            .keep_alive = false,
            .redirect_behavior = .unhandled,
            .headers = .{
                .accept_encoding = .{ .override = "identity" },
                .connection = .{ .override = "close" },
            },
            .extra_headers = state.extra_headers,
        }) catch return error.RequestFailed;
        state.request_initialized = true;

        if (method.requestHasBody()) {
            state.request.sendBodyComplete(@constCast(request.body)) catch return error.RequestFailed;
        } else {
            if (request.body.len != 0) return error.RequestFailed;
            state.request.sendBodiless() catch return error.RequestFailed;
        }
        state.response = state.request.receiveHead(&state.redirect_buffer) catch return error.RequestFailed;
        if (statusClass(state.response.head.status) != .success) return error.RequestFailed;
        state.reader = state.response.reader(&state.transfer_buffer);
        return state;
    }

    fn stream(self: *HttpStreamState) ResponseStream {
        return .{ .ptr = self, .next_chunk = nextChunkImpl, .deinit_fn = deinitImpl };
    }

    fn nextChunk(self: *HttpStreamState, buffer: []u8) ResponseStreamError!?[]const u8 {
        const reader = self.reader orelse return null;
        const len = reader.readSliceShort(buffer) catch |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
        };
        if (len == 0) return null;
        return buffer[0..len];
    }

    fn cleanup(self: *HttpStreamState) void {
        if (self.request_initialized) self.request.deinit();
        self.allocator.free(self.extra_headers);
        self.client.deinit();
    }

    fn deinit(self: *HttpStreamState) void {
        const allocator = self.allocator;
        self.cleanup();
        allocator.destroy(self);
    }

    fn nextChunkImpl(ptr: *anyopaque, buffer: []u8) ResponseStreamError!?[]const u8 {
        const self: *HttpStreamState = @ptrCast(@alignCast(ptr));
        return self.nextChunk(buffer);
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *HttpStreamState = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};

const StatusClass = enum { informational, success, redirect, client_error, server_error, other };

fn statusClass(status: std.http.Status) StatusClass {
    const code = @intFromEnum(status);
    return switch (code / 100) {
        1 => .informational,
        2 => .success,
        3 => .redirect,
        4 => .client_error,
        5 => .server_error,
        else => .other,
    };
}

fn parseMethod(method: []const u8) ?std.http.Method {
    if (std.mem.eql(u8, method, "GET")) return .GET;
    if (std.mem.eql(u8, method, "HEAD")) return .HEAD;
    if (std.mem.eql(u8, method, "POST")) return .POST;
    if (std.mem.eql(u8, method, "PUT")) return .PUT;
    if (std.mem.eql(u8, method, "DELETE")) return .DELETE;
    if (std.mem.eql(u8, method, "CONNECT")) return .CONNECT;
    if (std.mem.eql(u8, method, "OPTIONS")) return .OPTIONS;
    if (std.mem.eql(u8, method, "TRACE")) return .TRACE;
    if (std.mem.eql(u8, method, "PATCH")) return .PATCH;
    return null;
}
