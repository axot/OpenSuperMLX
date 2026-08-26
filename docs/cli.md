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
$BINARY benchmark audio.wav --reference-text "reference text" --json
```

All commands accept `--json` (structured output to stdout), `--quiet` (suppress stderr progress), and `--verbose`. The verbose flag is currently reserved; commands parse it but do not emit additional output yet.

## Command Reference

| Command | Purpose | Main arguments and subcommands |
|---|---|---|
| `transcribe <file>` | Transcribe one audio file | `--language`, `--model`, `--no-correction`, `--temperature` |
| `stream-simulate <file>` | Feed a file through the streaming pipeline | `--language`, `--model`, `--chunk-duration` |
| `correct <text>` | Apply configured LLM correction | `--file`, `--provider`, `--prompt` |
| `config` | Read or change application settings | `list`, `get <key>`, `set <key> <value>` |
| `recordings` | Inspect and manage recording history | `list`, `search <query>`, `show <id>`, `delete <id>`, `regenerate <id>` |
| `queue` | Manage imported-file transcription | `add <files>...`, `status`, `process` |
| `mic` | Inspect or select input devices | `list`, `select <device>` |
| `model` | Manage the model catalog and selection | `list`, `select <name>`, `add <repo-id>`, `remove <name>`; `download <name>` is a stub and does not fetch files yet |
| `benchmark <file>` | Measure accuracy, speed, and memory | `--language`, `--model`, `--runs`, `--wer-threshold`, `--reference-text`, `--suite` |
| `diagnose` | Print an environment snapshot | No command-specific arguments |

Run `$BINARY help <command>` or `$BINARY help <command> <subcommand>` for generated usage and defaults.

## Transcript MCP Bridge

The transcript MCP bridge is opt-in and binds only to `127.0.0.1`.

```bash
$BINARY config set transcriptMCPEnabled true
$BINARY config set transcriptMCPPort 17653
```

Restart the app after changing these settings. Then register the local MCP endpoint from an agent client:

```bash
codex mcp add opensupermlx-transcript --url http://127.0.0.1:17653/mcp
```

Available tools:

| Tool | Purpose |
|---|---|
| `get_transcript_delta` | Pull transcript segments after `after_cursor` |
| `search_transcript` | Search final transcript text with bounded context |
| `get_transcript_window` | Fetch nearby transcript context around a cursor |
| `list_transcript_sessions` | List recent live transcript sessions |

Tool responses keep human summaries in `content[].text`. Machine-readable values such as `next_cursor`, `segments`, and `matches` are returned only in `structuredContent`.

## Error Codes

With `--json`, command failures are written to stderr as `{"status":"error","command":"...","error":{"code":"...","message":"..."}}`.

| Code | Meaning |
|---|---|
| `model_not_found` | The requested model is not in the catalog |
| `model_not_cached` | The model must be downloaded before use |
| `model_load_failed` | The selected model could not be loaded |
| `audio_file_not_found` | The input path does not exist |
| `audio_format_unsupported` | The audio file cannot be decoded |
| `transcription_failed` | Transcription did not complete |
| `stream_timeout` | Streaming simulation exceeded its time limit |
| `llm_correction_failed` | Post-transcription correction failed |
| `database_error` | A recording database operation failed |
| `audio_file_missing` | A history entry no longer has usable audio |
| `invalid_config_key` | The configuration key is unknown |
| `invalid_config_value` | The value does not match the key's type |

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
