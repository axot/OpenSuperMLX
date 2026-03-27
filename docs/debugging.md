# Debugging

When investigating bugs or unexpected behavior, follow this priority order strictly.

## 1. Reproduce via CLI First (NOT the GUI)

Always attempt to reproduce the issue through a **unit test or CLI command** before launching the app manually:

- Write a focused test case in `OpenSuperMLXTests/` that triggers the bug
- Run it with the single-test command:
  ```bash
  xcodebuild test -scheme OpenSuperMLX -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath build -clonedSourcePackagesDirPath SourcePackages \
    CODE_SIGNING_ALLOWED=NO \
    -only-testing:OpenSuperMLXTests/RelevantTestClass/testMethodName
  ```
- If the bug involves audio processing or transcription logic, mock inputs and assert expected outputs
- If a test can reproduce it, the fix is verifiable — commit the test as a regression guard

**Only fall back to running the app** when the issue is inherently GUI-specific (e.g., menu bar rendering, keyboard shortcut capture, accessibility permissions).

## 2. Add Targeted Logger Statements

When the root cause isn't obvious from the test or stack trace, **instrument the code with `Logger` statements** to trace execution:

```swift
logger.warning("[DEBUG-ISSUE] state=\(state, privacy: .public) value=\(value, privacy: .public)")
```

- Use `warning` level for temporary diagnostic logs — always captured, no config needed
- Use a distinctive prefix like `[DEBUG-ISSUE]` so logs are easy to filter and easy to find/remove later
- Stream logs in a separate terminal while running the app or test:
  ```bash
  /usr/bin/log stream --process OpenSuperMLX --predicate 'messageType == "warning"' --level debug
  ```
- After narrowing the cause, add more targeted `debug`-level logs around the suspicious code path
- See [`logging.md`](logging.md) for Logger setup, privacy annotations, and reading commands

## 3. What NOT to Do

- **Never guess-and-fix** — reproduce first, then fix
- **Never use `print()`** — it doesn't appear in unified logs for GUI apps
- **Never leave diagnostic Logger statements in committed code** — remove all `[DEBUG-ISSUE]` logs before committing
- **Never skip writing a regression test** — if you can reproduce a bug in a test, that test must be committed with the fix
