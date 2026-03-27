# Pig

A demo coding agent built from scratch with raw HTTP calls to the Gemini API.

> This project is a learning/demo implementation, not a production-ready agent. It is intentionally small and straightforward so the core agent loop is easy to understand.

No SDKs, no frameworks — just:
- a chat loop
- conversation history
- a system prompt
- tool declarations
- a tool execution loop

## Features

Pig can:
- list files with `list_files`
- read files with `read_file`
- run shell commands with `run_bash`
- edit files with `edit_file`

## Requirements

- [Bun](https://bun.sh/)
- A Gemini API key: https://aistudio.google.com/apikey

## Setup

1. Add your key to `.env`:

```env
GEMINI_API_KEY=your-api-key-here
```

2. Install dependencies:

```bash
bun install
```

## Run

```bash
bun agent.ts
```

Then chat with Pig in the terminal.

## Example prompts

- `What files are in this project?`
- `Read agent.ts`
- `Run git status`
- `Create a file called notes.txt with hello inside`
- `Replace foo with bar in notes.txt`

## Project structure

- `agent.ts` — main agent implementation
- `.env` — API key (gitignored)
- `AGENTS.md` — project notes

## How it works

Pig runs an agent loop:

1. Read user input
2. Send conversation history to Gemini
3. Detect tool calls
4. Execute tools locally
5. Send tool results back to Gemini
6. Repeat until Gemini returns text

## Notes

- Built with Bun + TypeScript
- Uses the Gemini `generateContent` HTTP API directly
- Tool results are returned to Gemini with `role: "function"`
