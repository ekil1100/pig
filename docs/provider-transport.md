# Provider Transport

M1 separates provider parsing from transport. Recorded fixtures use in-memory/file-backed data; live provider checks are explicit.

## Request Ownership

`transport.Request` owns method, URL, headers, and body allocated by a request builder. Call `Request.deinit(allocator)` when done.

Authorization headers must not be logged.

## Response Stream Contract

A response stream exposes chunked bytes. Returned chunk slices are valid until the next chunk call or stream deinit. Parser code must copy data if it needs to retain it.

## Offline Transports

Default tests use recorded fixtures and fake/recorded streams. They do not use network and do not read real credentials.

## Live Smoke

Run:

```bash
zig build provider-live
```

Behavior:

- `PIG_PROVIDER_LIVE != 1`: skipped, exit 0
- live enabled but required env missing: skipped with missing variable names, exit 0
- env complete but live transport unsupported: nonzero diagnostic
- provider/API failure: nonzero diagnostic without API key

M1 currently keeps live transport behind this harness so default development stays deterministic.


## M1 Request Builder Limits

The M1 OpenAI-compatible request builder serializes simple text message content only. It does not yet serialize tool definitions, tool result messages, images, thinking blocks, or multi-block content. M1 parsers can read recorded tool-call streams; full outgoing tool-use request support belongs with later agent/tool milestones.

## Live Transport Status

M1 includes the `provider-live` harness and unsupported-transport diagnostic. Actual stdlib HTTP or curl live streaming transport is deferred unless explicitly prioritized later.
