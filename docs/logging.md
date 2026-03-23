# Logging

Uses Apple's unified logging via `os.Logger`.

## Setup

```swift
import os.log

private let logger = Logger(subsystem: "OpenSuperMLX", category: "YourCategory")
```

## Usage

```swift
logger.info("Model loaded: \(modelId, privacy: .public)")
logger.warning("Unexpected state: \(value, privacy: .public)")
logger.error("Failed: \(error, privacy: .public)")
logger.debug("[DEBUG] Verbose info: \(details, privacy: .public)")
```

- `privacy: .public` — visible in log output (default redacts interpolated values)
- `debug` — only appears when debug logging is enabled or streaming with `--level debug`
- `warning` — always captured, good for temporary diagnostic logs

## Reading Logs

```bash
# Stream live (filter by category)
/usr/bin/log stream --process OpenSuperMLX --predicate 'category == "FillerDebug"' --level debug

# Stream all app logs
/usr/bin/log stream --process OpenSuperMLX --level debug

# Search recent logs
/usr/bin/log show --process OpenSuperMLX --last 5m --predicate 'category == "MLXEngine"'
```

**Note:** Use `/usr/bin/log`, not `log` — zsh has a builtin `log` that conflicts.

## Conventions

- One `logger` per file, `private let`, category matches the primary type name
- Use `debug` for verbose/temporary output, `info` for milestones, `warning` for diagnostics, `error` for failures
- Never use `print()` — it doesn't appear in unified logs for GUI apps
