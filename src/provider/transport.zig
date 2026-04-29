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

pub const TransportError = error{ UnsupportedTransport, RequestFailed };

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
