# Provider Fixtures

Provider fixtures are recorded or hand-written samples for M1 provider tests.

Rules:

- Do not include real API keys, auth tokens, or user prompts from real sessions.
- Use fake keys such as `test-openai-key` only in auth fixtures.
- Default tests must use these fixtures offline.
- Live provider checks must be explicitly enabled with `PIG_PROVIDER_LIVE=1` and real credentials from the environment.

Fixture kinds:

- `*.sse`: text/event-stream body samples.
- `response-error.json`: non-streaming HTTP error body samples.
- `auth/*.json`: fake auth/config samples for resolver tests.
