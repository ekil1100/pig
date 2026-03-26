# Pig

gemini/typescript coding agent built from scratch with raw HTTP calls.

## Setup
1. Add your API key to `.env`
2. Key URL: https://aistudio.google.com/apikey

## Run
`bun agent.ts`

## Notes
- Prefer Bun as the runtime for this project.
- Future run/test instructions should use Bun instead of Node/tsx.

## How it works
Agentic loop: prompt -> LLM -> tool call -> execute -> result back -> LLM -> ... -> text response

## Tools
- [x] list_files
- [x] read_file
- [x] run_bash
- [x] edit_file

## Structure
- `agent.ts` -- main agent source
- `.env` -- API key (gitignored)
