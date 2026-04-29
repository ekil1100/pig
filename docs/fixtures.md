# Fixture Policy

Fixtures are intentionally small and offline-only. They provide stable input for tests without copying large reference repositories or user data.

## Directories

- `fixtures/pi-mono`: compact metadata derived from the reference product boundary.
- `fixtures/fake-provider`: small JSONL provider-event samples reserved for M2 tests.
- `fixtures/provider`: M1 recorded/hand-written provider SSE, response-error, auth, and config fixtures.

## Rules

- Never include real secrets, API keys, tokens, auth files, or user sessions.
- Auth fixtures may contain fake keys such as `test-openai-key` only.
- Do not copy large source trees or raw real sessions.
- Prefer compact metadata and short JSON/JSONL/SSE behavior samples.
- Tests must pass without `/home/like/workspace/pi-mono` or `/Users/like/workspace/pi-mono` existing.
- Default tests must not access live providers.
- Live provider checks require explicit `PIG_PROVIDER_LIVE=1` and credentials from environment variables.

## Provider Fixture Files

- `fixtures/provider/openai-compatible/*.sse`: OpenAI-compatible streaming samples.
- `fixtures/provider/openai-compatible/response-error.json`: non-streaming HTTP error body sample.
- `fixtures/provider/anthropic/*.sse`: Anthropic Messages streaming samples.
- `fixtures/provider/anthropic/response-error.json`: Anthropic HTTP error body sample.
- `fixtures/provider/auth/*.json`: fake auth/config samples.

## M0 Files

- `fixtures/README.md`
- `fixtures/pi-mono/package-list.json`
- `fixtures/pi-mono/package-readmes.json`
- `fixtures/pi-mono/cli-samples.jsonl`
- `fixtures/fake-provider/empty-turn.jsonl`
