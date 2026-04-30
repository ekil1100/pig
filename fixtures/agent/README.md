# Agent Fixtures

Agent fixtures are offline M2 scripts for fake provider/tool behavior.

Rules:

- Do not include API keys, real provider responses, private prompts, or real filesystem paths.
- Keep payloads small and deterministic.
- Treat rows as documentation/golden seeds in M2; runtime replay can be added later.
