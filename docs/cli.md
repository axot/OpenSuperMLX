# CLI Test Harness

```bash
BINARY=build/Build/Products/Debug/OpenSuperMLX.app/Contents/MacOS/OpenSuperMLX

# List all commands
$BINARY --help

# Per-command usage
$BINARY help transcribe
```

## Quick Start

```bash
# Smoke test — always works, no model needed
$BINARY diagnose --json

# Transcribe a file
$BINARY transcribe audio.wav --json

# Simulate streaming pipeline (exercises ring buffer → inference → events)
$BINARY stream-simulate audio.wav --json

# Run benchmark with accuracy check
$BINARY benchmark audio.wav --expected-text "reference text" --json
```

All commands accept `--json` (structured output to stdout) and `--quiet` (suppress stderr progress).

## Running CLI Tests

```bash
# All CLI tests
xcodebuild test -scheme OpenSuperMLX -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build -clonedSourcePackagesDirPath SourcePackages \
  CODE_SIGNING_ALLOWED=NO -only-testing:OpenSuperMLXTests

# Single command test class
xcodebuild test -scheme OpenSuperMLX -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build -clonedSourcePackagesDirPath SourcePackages \
  CODE_SIGNING_ALLOWED=NO -only-testing:OpenSuperMLXTests/TranscribeCommandTests
```

## Pre-Commit CLI Verification

**If a CLI command can exercise the code path you changed, run it before committing.**

| What you changed | Verify with |
|---|---|
| Transcription, model, ITN | `transcribe <audio> --json` |
| Streaming pipeline | `stream-simulate <audio> --json` |
| LLM correction | `correct "text" --json` |
| Settings / AppPreferences | `config get <key>` |
| Recordings DB | `recordings list --json` |
| Audio devices | `mic list --json` |
| Model catalog | `model list --json` |
| Any change (minimum bar) | `diagnose --json` |

For bug fixes: reproduce via CLI first → fix → verify via CLI → include repro steps in commit message.
