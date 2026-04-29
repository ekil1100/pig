# Provider Auth

M1 implements provider-local auth resolution only. Full resource/config hierarchy is deferred to M7.

## Source Priority

1. Explicit provider config (`api_key` passed by caller)
2. Explicit auth JSON path
3. Injected environment reader

This priority keeps tests deterministic and prevents real local env vars from overriding fixtures.

## Environment Variables

- OpenAI-compatible: `PIG_OPENAI_COMPAT_API_KEY`
- Anthropic: `ANTHROPIC_API_KEY` or `PIG_ANTHROPIC_API_KEY`
- Gemini: `GEMINI_API_KEY` or `PIG_GEMINI_API_KEY`

Live smoke also requires:

- `PIG_PROVIDER_LIVE=1`
- `PIG_OPENAI_COMPAT_BASE_URL`
- `PIG_OPENAI_COMPAT_API_KEY`
- `PIG_OPENAI_COMPAT_MODEL`

## Auth JSON Fixture Format

```json
{
  "providers": {
    "openai_compatible": { "api_key": "test-openai-key" },
    "anthropic": { "api_key": "test-anthropic-key" }
  }
}
```

Auth fixtures must use fake keys only. Real keys must never be committed.

## Redaction Rule

Provider auth errors must describe what is missing, not echo secret values. Tests assert fake key strings do not appear in missing-key error messages.
