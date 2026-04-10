# CLI Test Harness Design

> **Date**: 2026-04-10
> **Status**: Draft
> **Scope**: Expand CLI from single `--transcribe` flag to a full ArgumentParser-based test harness covering all UI features.

## Goal

Build a CLI test harness so that AI agents and CI pipelines can exercise the same business logic as the GUI, reproduce bugs, and run regression benchmarks — all without UI interaction.

## Background

OpenSuperMLX currently has a minimal CLI: `--transcribe <file> [--language <lang>]` that feeds audio chunks directly to `StreamingInferenceSession`. This bypasses most of the app's service layer (ring buffer, feedTask, TranscriptionService orchestration, LLM correction, recording store, etc.).

The GUI has 80+ user-facing features across recording, transcription, settings, device management, and more. When bugs are reported, they are hard to reproduce because they require UI interaction. A CLI that mirrors these features lets AI agents script reproduction steps and CI pipelines catch regressions automatically.

## Architecture Decision

**Approach A (chosen): ArgumentParser subcommands in existing binary.**

Replace raw `CommandLine.arguments` parsing in `main.swift` with Swift ArgumentParser's `AsyncParsableCommand`. No subcommand launches GUI; subcommands run headlessly.

**Why not separate CLI target (Approach B)?** Xcode multi-target source file sharing is complex to maintain.

**Why not full SPM library/CLI/app split (Approach C)?** Major refactor — viable as a future migration but too costly now. Approach A lays the groundwork.

## Infrastructure Changes

1. **Add Swift ArgumentParser** as SPM dependency.
2. **Rewrite `main.swift`**: root `AsyncParsableCommand`, no subcommand launches GUI.
3. **`StreamingAudioService`**: add `startStreamingFromFile(url:)` method that writes to the existing ring buffer without initializing AVAudioEngine. Skips AVAudioEngine to work on headless CI.
4. **`MicrophoneService`**: add protocol abstraction for device change events (for unit testing mic hot-swap).

## Output Format

All subcommands share global flags:

| Flag | Effect |
|---|---|
| `--json` | Structured JSON output to stdout |
| `--quiet` | Suppress progress/status on stderr |
| `--verbose` | Detailed logging on stderr |

**stdout/stderr separation**: stdout contains only the final result (text or JSON). stderr contains progress, logs, and diagnostics.

**Exit codes** (3 total, following Swift ArgumentParser convention):

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | Runtime failure |
| `64` | Bad arguments (ArgumentParser handles automatically via `EX_USAGE`) |

Detailed error types are in the JSON `error.code` field, not in exit codes.

## Commands

### `transcribe`

Batch file transcription. Same code path as dragging a file into the UI.

```
transcribe <file> [--language <lang>] [--model <repo-id>] [--no-correction] [--temperature <float>]
```

**Code path**: `TranscriptionService.transcribeAudio(url:settings:)` → `MLXEngine.transcribeAudio()` → ITN → Autocorrect → LLM correction (if enabled).

### `stream-simulate`

Stream simulation from a file. Exercises the full streaming pipeline including ring buffer and feedTask — same code path as pressing the record hotkey.

```
stream-simulate <file> [--language <lang>] [--model <repo-id>] [--chunk-duration <seconds>]
```

**How it works:**
1. Load audio file as `[Float]` array at 16kHz.
2. Write all audio data into `StreamingAudioService`'s ring buffer at full speed.
3. The existing `feedTask` drains the ring buffer and feeds `StreamingInferenceSession.feedAudio()`.
4. The existing `eventTask` reads inference events.
5. Append 660ms of silence to flush the final partial chunk (reference: sherpa-onnx tail padding).

**Pipeline coverage:**

| Step | Production (real mic) | stream-simulate | transcribe (batch) |
|---|---|---|---|
| AVAudioEngine capture | Yes | No (skipped) | No |
| Ring buffer write | Yes | Yes | No |
| feedTask drain | Yes | Yes | No |
| StreamingInferenceSession | Yes | Yes | No (uses batch path) |
| Event processing | Yes | Yes | No |
| Batch inference (MLXEngine) | No | No | Yes |

**Default chunk duration**: 500ms. Reference: FluidAudio, Vosk, sherpa-onnx all use 500ms.

**No real-time pacing**: Full speed. Does not affect results — model processes waveform data, not timestamps.

**CI compatibility**: Skips AVAudioEngine initialization. Works on headless CI.

### `correct`

Test LLM correction in isolation.

```
correct <text|--file path> [--provider bedrock|openai] [--prompt <custom-prompt>]
```

### `config`

Read and write settings.

```
config list
config get <key>
config set <key> <value>
```

### `recordings`

Manage recordings in the database.

```
recordings list [--limit 20] [--offset 0]
recordings search <query> [--limit 20]
recordings show <id>
recordings delete <id|--all>
recordings regenerate <id>
```

### `queue`

Manage file transcription queue.

```
queue add <file...>
queue status
queue process
```

### `mic`

View and configure audio input devices.

```
mic list
mic select <id|name>
```

### `model`

Manage transcription models.

```
model list
model select <repo-id>
model add <repo-id>
model remove <repo-id>
model download <repo-id>
```

### `benchmark`

Measure transcription accuracy, speed, and memory.

```
benchmark <file|--suite> \
  [--expected-text "..."] [--expected-file ref.txt] \
  [--model <repo-id>] [--language <lang>] \
  [--wer-threshold 0.1] [--runs 3] [--warmup 1]
```

**Three metrics:**

| Metric | How | Reference |
|---|---|---|
| Accuracy | WER for English; CER for Chinese/Japanese (character-level, no segmentation) | OpenAI Whisper uses `split_letters=True` for CJK |
| Speed | RTF = processing_time / audio_duration. 1 warm-up + 3 timed runs, report mean | WhisperKit, mlx-lm benchmark pattern |
| Memory | `phys_footprint` from `task_info()` — total process memory (CPU + GPU on Apple Silicon unified memory) | WhisperKit `AppMemoryChecker` |

**WER/CER implementation**: Vendor WhisperKit's 4 standalone Swift files (MIT license).

**CER for Chinese/Japanese**: Character-level comparison, no jieba segmentation. Industry standard.

**Memory measurement**: `phys_footprint` captures total CPU + GPU memory on Apple Silicon (unified memory). Record baseline before inference, peak during inference, report delta.

**Benchmark test audio files** (one per language, committed to repo):

| Language | File | Duration | License |
|---|---|---|---|
| English | `jfk.wav` (JFK inaugural address) | 11s | Public domain |
| Chinese | TBD — record or extract from AISHELL-1 | 5-10s | TBD |
| Japanese | TBD — record or use existing clip | 5-10s | TBD |

**JSON output:**
```json
{
  "file": "jfk.wav",
  "language": "en",
  "accuracy": {
    "metric": "WER",
    "score": 0.05,
    "substitutions": 1,
    "insertions": 0,
    "deletions": 0
  },
  "performance": {
    "audio_duration_s": 11.0,
    "processing_time_s": 1.1,
    "rtf": 0.10,
    "speed_factor": 10.0,
    "runs": 3,
    "rtf_stddev": 0.01
  },
  "memory": {
    "peak_total_mb": 680,
    "baseline_mb": 120,
    "inference_delta_mb": 560
  },
  "pass": true
}
```

### `diagnose`

One-command environment snapshot.

```
diagnose
```

Outputs: macOS version, chip model, available memory, installed models, current mic, permissions, key settings, app version.

## Mic Hot-Swap Testing

Tested via unit tests with protocol abstraction, not CLI commands. Reference: Telephone project (VoIP app).

**Pattern:**
1. Protocol-abstract device change events.
2. Injectable `isDeviceAlive` closure — tests inject `{ _ in false }` to simulate device death.
3. Test `AVAudioEngineConfigurationChange` by manually posting notification.

**Scenarios:** device disappears during recording, engine config change, configured device missing, rapid successive changes.

## Research References

| Project | What we learned |
|---|---|
| WhisperKit | CLI split; stream simulation; WER Swift impl; benchmark |
| whisper.cpp | bench (perf only); stream chunk params |
| FluidAudio | 500ms chunks; Task.yield() pacing |
| sherpa-onnx | 660ms tail padding; RTF calc |
| Vosk | 250ms file chunks; no-sleep feeding |
| OpenAI Whisper | CJK CER with split_letters; datasets |
| Swift ArgumentParser | 3 exit codes; AsyncParsableCommand |
| SwiftFormat | Library + CLI shim; AGENTS.md |
| Telephone | Protocol spy for device change testing |
| OpenAI codex | app-server-test-client; AGENTS.md |
| OpenAI openai-agents-python | Skill policies; runtime-behavior-probe |
| Anthropic claude-agent-sdk-python | Three-tier testing |
