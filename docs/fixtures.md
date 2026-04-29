# Fixture Policy

M0 fixtures are intentionally small and offline-only. They provide stable input for tests without copying large reference repositories or user data.

## Directories

- `fixtures/pi-mono`: compact metadata derived from the reference product boundary.
- `fixtures/fake-provider`: small JSONL provider-event samples reserved for M1/M2 tests.

## Rules

- Never include secrets, API keys, tokens, auth files, or real user sessions.
- Do not copy large source trees.
- Prefer metadata, summaries, and short JSON/JSONL behavior samples.
- Tests must pass without `/home/like/workspace/pi-mono` or `/Users/like/workspace/pi-mono` existing.
- Live provider data belongs in explicitly opted-in live tests, not default fixtures.

## M0 Files

- `fixtures/README.md`
- `fixtures/pi-mono/package-list.json`
- `fixtures/pi-mono/package-readmes.json`
- `fixtures/pi-mono/cli-samples.jsonl`
- `fixtures/fake-provider/empty-turn.jsonl`
