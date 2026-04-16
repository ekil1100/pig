# Pig

Local coding agent built from scratch with Bun, TypeScript, and raw Gemini HTTP calls.

## Project Goal

Pig is currently a small teaching/demo agent. The near-term goal is `v0.2`: turn it into a usable local coding-agent CLI without overcomplicating the architecture.

That means prioritizing:

1. Session persistence and resume
2. Confirmation before `run_bash`
3. Confirmation and preview before `edit_file`
4. Local slash commands
5. Basic project-context loading
6. Clear tool/event logging

## Current State

- Runtime: Bun
- Language: TypeScript
- Entry point: `agent.ts`
- Current implementation: mostly single-file
- Model API: Gemini `generateContent` over raw HTTP
- Implemented tools:
  - `list_files`
  - `read_file`
  - `run_bash`
  - `edit_file`

## Working Rules

- Prefer Bun for all run and test commands.
- Do not switch examples or scripts to Node, `tsx`, or other runtimes unless the user explicitly asks.
- Keep the implementation simple. Avoid introducing frameworks or deep abstractions unless they directly support the `v0.2` plan.
- Preserve the core agent loop shape:
  `user input -> model -> tool call -> local execution -> tool result -> model -> final text`
- Treat this repo as local-first CLI software, not a web app or multi-agent platform.
- Never commit secrets. `.env` is local-only and should stay gitignored.

## Expected Commands

- Install deps: `bun install`
- Run the agent: `bun agent.ts`

If you add tests or validation scripts, prefer Bun-native commands.

## Implementation Guidance

When making nontrivial changes, align with the `Pig v0.2` docs in `docs/`:

- `docs/pig-v0.2-prd.md`
- `docs/pig-v0.2-technical-design.md`
- `docs/pig-v0.2-issues.md`

Preferred implementation order:

1. Extract shared types
2. Extract model adapter
3. Add session store
4. Split tools into modules
5. Add confirmation UI
6. Add tool-event logging
7. Refactor agent loop
8. Add slash commands and REPL
9. Add project-context loader

## Scope Boundaries

For `v0.2`, do not expand into:

- Multi-agent workflows
- Web UI
- Cloud sync
- Plugin/runtime ecosystems
- RAG/vector search
- Complex patch engines
- Multi-model routing

Those may come later, but they are not the current target.

## Files

- `agent.ts`: current main implementation
- `README.md`: user-facing project overview
- `docs/`: product and architecture notes
- `.env`: local Gemini API key, not committed
