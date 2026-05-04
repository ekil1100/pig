# Pig Resources

M7 adds the first product resource loading layer. The `resources` module stays data-only: it parses settings, model registry files, context files, and resource metadata, then returns DTOs with source paths and warnings. It does not construct model clients, run tools, render TUI, or execute skills/packages.

## Paths

Global resources live under `~/.pig/agent`:

```text
settings.json
auth.json
models.json
skills/
prompts/
themes/
packages/
```

Project resources live under `<cwd>/.pig`:

```text
settings.json
models.json
skills/
prompts/
themes/
packages/
```

The `.pig` namespace is intentional. Implementations must not write M7 resources under `.pi`.

## Settings

Settings merge in this order:

```text
defaults -> global settings.json -> project settings.json -> CLI flags
```

Objects merge by field. Arrays replace the previous value. Missing files produce warnings, not failures. Invalid selected values, invalid settings JSON, and invalid models JSON are failures.

## Models

The model registry starts with built-ins, then applies global and project `models.json`. Project entries override global entries with the same id and produce collision warnings.

`settings.model` is a registry id. A model entry's `model` field is the provider-facing model name. `resources.models` keeps `provider_id` as a string; `app.model_factory` maps it to `provider.ProviderKind`.

## Context Files

Context discovery reads `AGENTS.md`, `CLAUDE.md`, `SYSTEM.md`, and `APPEND_SYSTEM.md` from the resolved workspace root down to the current working directory. Discovery must not read parent directories above the workspace root.

The app layer injects the synthesized prompt into `AgentConfig.system_prompt`. `core.agent` does not read resource files.

## Interactive Reload

M7 supports a minimal `/reload` in scripted interactive mode. It reloads settings/models/context/resource metadata, updates the next-turn system prompt, and reports a status line. Full slash command workflows belong to M8.
