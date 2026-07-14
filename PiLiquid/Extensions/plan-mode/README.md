# Plan Mode

Pi Liquid ships a vendored Plan Mode extension for read-only exploration before
implementation. It gates tools and steers the model toward a plain-language
plan; it does not parse checklist syntax or decide when execution should begin.

## Commands and surfaces

- `/plan` — toggle Plan Mode for the active session
- `/plan <prompt>` — enable Plan Mode and immediately submit `<prompt>`
- `--plan` — start a `pi` session in Plan Mode
- `Ctrl+Alt+P` — toggle Plan Mode in the terminal TUI
- Pi Liquid composer chip — shows the live Plan state and exits it with `×`

The extension posts a `plan-mode` footer status over RPC. Pi Liquid strips the
terminal ANSI styling and presents that state as a native composer chip.

## Tool policy while enabled

- `edit` and `write` are removed with `setActiveTools`.
- `bash` is restricted by `utils.ts` to a conservative read-only allowlist:
  inspection (`cat`, `head`, `less`), search (`grep`, `rg`, `fd`), directory
  listing (`ls`, `tree`), and git reads (`status`, `log`, `diff`).
- Commands that write files, install software, commit, or escalate privileges
  are rejected.
- A `plan-mode-context` custom message asks the model to explore and return an
  implementation plan without changing the project.
- Plan state persists across resume through an appended custom session entry.

Plan Mode is a workflow guard, not a security sandbox. The command allowlist is
deliberately conservative, but users should still review agent requests.

## Executing a plan

Execution is intentionally separate. Pi Liquid offers **Execute Plan in New
Session**, which seeds a fresh normal-mode session with the latest assistant
plan through `SessionManager.executePlan`. The original planning conversation
stays open for reference.

This behavior replaces the stock example's regex-based todo parsing, progress
widget, and “Execute the plan?” dialog, which were brittle against real model
output and coupled planning to execution timing.

Return to the [Pi Liquid README](../../../README.md).
