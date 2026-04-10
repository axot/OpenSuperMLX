# Debugging

Reproduction strategy and diagnostic logging for bug investigations. The debugging methodology (hypothesis → verify → fix) lives in dedicated skills.

## Reproducing Issues

Reproduce the issue **outside the GUI** whenever possible, in this priority order:

1. **CLI first** — use `--transcribe` or other CLI modes to reproduce the issue end-to-end. If the relevant code path has no CLI entry point, **add one** so the bug can be reproduced and verified without launching the app.
2. **Unit test** — when the problem is clearly scoped to a single function or module's output, write a focused test case to reproduce it.

If neither CLI nor unit test can reproduce the issue (e.g., the bug is in a GUI component itself like button rendering or shortcut capture), **stop and report to the user** — explain what was attempted, why it cannot be reproduced programmatically, and let the user decide how to proceed.

## Diagnostic Logging

Add targeted `Logger` statements to trace execution and verify assumptions:

```swift
logger.warning("[DEBUG-ISSUE] state=\(state, privacy: .public) value=\(value, privacy: .public)")
```

- Use `warning` level for temporary diagnostic logs — always captured, no config needed
- Use a distinctive prefix like `[DEBUG-ISSUE]` so logs are easy to filter and easy to find/remove later
- After reproducing the issue, read logs with `log show`:
  ```bash
  /usr/bin/log show --process OpenSuperMLX --last 5m --predicate 'messageType >= "warning"' --level debug
  ```
- Adjust `--last` duration as needed (e.g., `--last 1m`, `--last 30s`)
- After narrowing the cause, add more targeted `debug`-level logs around the suspicious code path
- See [`logging.md`](logging.md) for Logger setup, privacy annotations, and reading commands

## Rules

- **Never use `print()`** — it doesn't appear in unified logs for GUI apps
- **Never leave diagnostic Logger statements in committed code** — remove all `[DEBUG-ISSUE]` logs before committing
