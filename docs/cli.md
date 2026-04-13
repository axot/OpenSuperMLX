# CLI Test Harness

The binary doubles as a CLI test harness. When launched with a subcommand it runs headlessly; with no subcommand it launches the GUI as usual.

```bash
BINARY=build/Build/Products/Debug/OpenSuperMLX.app/Contents/MacOS/OpenSuperMLX
```

## Commands

| Command | Purpose | Example |
|---|---|---|
| `transcribe` | Batch file transcription (same path as drag-and-drop) | `$BINARY transcribe audio.wav --language zh --json` |
| `stream-simulate` | Streaming pipeline via ring buffer injection (same path as record hotkey) | `$BINARY stream-simulate audio.wav --chunk-duration 0.5 --json` |
| `correct` | LLM correction in isolation | `$BINARY correct "raw text" --provider bedrock --json` |
| `config` | Read/write AppPreferences | `$BINARY config list --json` |
| `recordings` | CRUD on recording database | `$BINARY recordings list --limit 10 --json` |
| `queue` | Manage file transcription queue | `$BINARY queue add file1.wav file2.wav --json` |
| `mic` | List and select audio devices | `$BINARY mic list --json` |
| `model` | Manage model catalog | `$BINARY model list --json` |
| `benchmark` | WER/CER accuracy + RTF speed + memory | `$BINARY benchmark audio.wav --expected-text "ref" --json` |
| `diagnose` | Environment snapshot | `$BINARY diagnose --json` |

Use `$BINARY help <command>` for detailed flags and subcommands.

## Global Flags

All commands accept these flags **after** the subcommand name:

- `--json` — structured JSON on stdout (default: human-readable)
- `--quiet` — suppress progress on stderr
- `--verbose` — detailed logging on stderr

## Output Convention

- **stdout**: result only — safe to pipe to `jq`
- **stderr**: progress, logs, diagnostics
- **Exit codes**: `0` success, `1` runtime failure, `64` bad arguments

## Running CLI Tests

```bash
# All CLI tests
xcodebuild test -scheme OpenSuperMLX -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build -clonedSourcePackagesDirPath SourcePackages \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:OpenSuperMLXTests/CLIRootCommandTests \
  -only-testing:OpenSuperMLXTests/CLIOutputTests \
  -only-testing:OpenSuperMLXTests/TranscribeCommandTests \
  -only-testing:OpenSuperMLXTests/StreamSimulateCommandTests \
  -only-testing:OpenSuperMLXTests/CorrectCommandTests \
  -only-testing:OpenSuperMLXTests/ConfigCommandTests \
  -only-testing:OpenSuperMLXTests/RecordingsCommandTests \
  -only-testing:OpenSuperMLXTests/QueueCommandTests \
  -only-testing:OpenSuperMLXTests/MicCommandTests \
  -only-testing:OpenSuperMLXTests/ModelCommandTests \
  -only-testing:OpenSuperMLXTests/BenchmarkCommandTests \
  -only-testing:OpenSuperMLXTests/DiagnoseCommandTests

# Single command test class
xcodebuild test -scheme OpenSuperMLX -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build -clonedSourcePackagesDirPath SourcePackages \
  CODE_SIGNING_ALLOWED=NO -only-testing:OpenSuperMLXTests/ConfigCommandTests

# Smoke test (quick sanity check)
$BINARY diagnose --json 2>/dev/null | python3 -m json.tool
```

## Error Codes

JSON `error.code` field values:

`model_not_found`, `model_not_cached`, `model_load_failed`, `audio_file_not_found`, `audio_format_unsupported`, `transcription_failed`, `stream_timeout`, `llm_correction_failed`, `database_error`, `audio_file_missing`, `invalid_config_key`, `invalid_config_value`

## Pre-Commit Verification Lookup

| What you changed | Verify with |
|---|---|
| Transcription, model loading, ITN, autocorrect | `transcribe <audio> --json` |
| Streaming pipeline, ring buffer, events | `stream-simulate <audio> --json` |
| LLM correction, provider config | `correct "text" --json` |
| AppPreferences, settings | `config get <key>` / `config set <key> <val>` |
| RecordingStore, database | `recordings list --json` |
| TranscriptionQueue | `queue status --json` |
| MicrophoneService, devices | `mic list --json` |
| MLXModelManager, model catalog | `model list --json` |
| Any change (minimum bar) | `diagnose --json` |
