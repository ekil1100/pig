# Provider Auth

Provider auth resolution remains provider-local and deterministic. M7 wires that resolver into app runtime assembly through the resource/config layer, so print and interactive modes can resolve the selected model's provider, auth JSON path, and injected process environment without moving secret handling into `resources`.

## Source Priority

1. Explicit provider config (`api_key` passed by caller)
2. Explicit auth JSON path
3. Injected environment reader

This priority keeps tests deterministic and prevents real local env vars from overriding fixtures.

## M7 Runtime Integration

`resources.settings` and `resources.models` only describe the selected provider/model as data. `app.config_runtime` resolves the global/project resource snapshot, and `app.model_factory` maps the selected model's `provider_id` to `provider.ProviderKind` before calling `provider.auth.resolveApiKey`.

The default auth JSON path comes from `~/.pig/agent/auth.json`. Project settings can select models, but secrets still come only from explicit test config, auth JSON, or the injected environment reader. The resource layer must not read API keys or construct provider clients.

## Environment Variables

- OpenAI-compatible: `PIG_OPENAI_COMPAT_API_KEY`
- DeepSeek: `DEEPSEEK_API_KEY` or `PIG_DEEPSEEK_API_KEY`
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
    "deepseek": { "api_key": "test-deepseek-key" },
    "anthropic": { "api_key": "test-anthropic-key" }
  }
}
```

Auth fixtures must use fake keys only. Real keys must never be committed.

## Redaction Rule

Provider auth errors must describe what is missing, not echo secret values. Tests assert fake key strings do not appear in missing-key error messages.
