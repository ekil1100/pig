# Tool Approval

M3 introduces a non-UI approval abstraction for risky built-in tools.

## Defaults

Approval is required by default for:

- `write`
- `edit`
- `bash`

Approval is not required by default for:

- `read`
- `grep`
- `find`
- `ls`

## Policy interface

`ApprovalPolicy.decide(request)` returns `allow` or `deny`. Denial is a normal decision, not an infrastructure error. Approval backend failures use `ApprovalError`.

M3 includes test policies:

- `AllowAllApproval`
- `DenyAllApproval`
- `RecordingApproval`

## Preview

Write/edit/bash build deterministic preview JSON before requesting approval. M3 stores preview data as JSON and tests it, but does not render an interactive UI. TUI rendering belongs to later milestones.

If approval is denied, tools return structured JSON with `ok:false` and `is_error=true` and do not perform side effects.
