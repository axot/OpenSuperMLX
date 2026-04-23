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

## End-to-End Streaming Tests

Automated XCTest suite that exercises the full streaming pipeline with a real model and real audio. Requires:

1. Model downloaded locally (`mlx-community/Qwen3-ASR-1.7B-8bit`)
2. Audio file path provided via `OPENSUPERMLX_E2E_AUDIO` environment variable

Tests skip automatically if either prerequisite is missing.

```bash
# Run all E2E streaming tests with a short audio file
OPENSUPERMLX_E2E_AUDIO=/path/to/audio.wav \
  xcodebuild test -scheme OpenSuperMLX -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build -clonedSourcePackagesDirPath SourcePackages \
  CODE_SIGNING_ALLOWED=NO -only-testing:OpenSuperMLXTests/StreamingE2ETests

# Run a single E2E test
OPENSUPERMLX_E2E_AUDIO=/path/to/audio.wav \
  xcodebuild test -scheme OpenSuperMLX -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build -clonedSourcePackagesDirPath SourcePackages \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:OpenSuperMLXTests/StreamingE2ETests/testStreamingProducesNonEmptyText

# Long-duration stability test (audio ≥2 min required, otherwise skipped)
OPENSUPERMLX_E2E_AUDIO=/path/to/long-audio.wav \
  xcodebuild test -scheme OpenSuperMLX -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build -clonedSourcePackagesDirPath SourcePackages \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:OpenSuperMLXTests/StreamingE2ETests/testStreamingNoStallOnLongAudio
```

| Test | What it verifies | Audio requirement |
|---|---|---|
| `testStreamingProducesNonEmptyText` | Basic pipeline: audio in → text out | Any duration |
| `testStreamingReceivesIntermediateUpdates` | `displayUpdate` events flow during streaming | Any duration |
| `testStreamingCompletesWithinTimeLimit` | No hang — processing < 5× audio duration | Any duration |
| `testStreamingTextGrowsOverTime` | Text accumulates across multiple updates | Any duration |
| `testStreamingNoStallOnLongAudio` | No stall >60s between updates (regression for backpressure fix) | ≥2 minutes |
| `testStreamingStatsReceived` | Stats events with peak memory are emitted | Any duration |
