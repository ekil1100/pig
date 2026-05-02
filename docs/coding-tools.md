# Coding Tools

M3 adds built-in local coding tools under `src/tools` and adapts them to the M2 agent runtime through `tools.registry`.

The runtime passes the active registry's tool specs into every model request. A spec includes name, description, JSON schema, display label, risk level, and access classification; concrete tools keep their approval and execution behavior inside `src/tools`.

## Tools

- `read`: read text files inside the workspace.
- `write`: create, overwrite, or append files after approval.
- `edit`: apply exact old-text replacements after approval.
- `bash`: run `bash -lc` in the workspace after approval.
- `grep`: literal text search.
- `find`: simple basename wildcard search using `*` and `?`.
- `ls`: sorted directory listing.

## Result JSON

Every tool returns valid JSON in `ToolExecutionResult.content_json`.

Expected user/tool errors return JSON with `ok:false` and `is_error=true`; they are not Zig runtime `ToolFailed` errors. This lets the model receive recoverable tool results.

## Path policy

Tools normalize workspace-relative paths, reject absolute paths by default, reject NUL bytes, and reject `..` traversal that escapes the workspace. M3 does not promise symlink-safe sandboxing.

## Limits

`ToolLimits` controls read size, result size, bash visible output size, bash capture size, and bash timeout. Bash is Unix/macOS-first in M3 and uses Zig child-process timeout support.

When bash stdout/stderr exceeds the visible output limit but stays under the capture limit, Pig truncates the JSON-visible field and writes the full stream to `spill_dir`. The result includes `stdout_full_output_path` and/or `stderr_full_output_path` when a spill file is created. Output beyond the capture limit is rejected with `output_too_large` to keep memory bounded.

## Search scope

M3 grep is literal-only. `literal=false` returns `unsupported_regex`. Full regex, `**` globbing, and full `.gitignore` semantics are later hardening work.
