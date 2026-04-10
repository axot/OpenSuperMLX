# Plan: CLI Test Harness

> **Spec**: `docs/superpowers/specs/2026-04-10-cli-test-harness-design.md`
> **Branch**: `cli-test-harness`
> **Worktree**: `../OpenSuperMLX-cli-test-harness`

## Prerequisites

```bash
git worktree add ../OpenSuperMLX-cli-test-harness -b cli-test-harness
```

All work happens in the worktree. Main working tree stays clean.

---

## Task 1: Add ArgumentParser and rewrite main.swift

**Goal**: Replace raw `CommandLine.arguments` parsing with Swift ArgumentParser. No subcommand → launch GUI. Any subcommand → run headlessly.

**TDD**:
1. Write test: `OpenSuperMLXTests/CLITests/CLIRootCommandTests.swift`
   - Test that `OpenSuperMLXCLI.parse([])` produces the root command (GUI launch path)
   - Test that `OpenSuperMLXCLI.parse(["transcribe", "file.wav"])` routes to TranscribeCommand
   - Test that `OpenSuperMLXCLI.parse(["--json", "transcribe", "file.wav"])` passes global flags
   - Test that invalid subcommands produce exit code 64
2. Verify tests fail (red).
3. Implement:
   - Add `swift-argument-parser` to `Package.resolved` / Xcode SPM dependencies
   - Create `OpenSuperMLX/CLI/CLIRoot.swift` — root `AsyncParsableCommand` with `--json`, `--quiet`, `--verbose` global flags
   - Rewrite `main.swift`: if `CommandLine.arguments` has subcommands → `CLIRoot.main()`, else → `OpenSuperMLXApp.main()`
   - Create stub subcommands (empty `run()` methods) for all 10 commands
4. Verify tests pass (green).
5. Verify: `lsp_diagnostics` clean on changed files.

**Files touched**: `main.swift`, `Package.swift` or `.xcodeproj` SPM config, new `OpenSuperMLX/CLI/` directory.

---

## Task 2: JSON output infrastructure and error handling

**Goal**: Build shared `CLIOutput` utility for consistent JSON/human-readable output, stdout/stderr separation, and error code mapping.

**TDD**:
1. Write test: `OpenSuperMLXTests/CLITests/CLIOutputTests.swift`
   - Test JSON success output format matches spec schema
   - Test JSON error output format with all 12 error codes
   - Test human-readable output mode
   - Test `--quiet` suppresses stderr
2. Verify tests fail.
3. Implement:
   - Create `OpenSuperMLX/CLI/CLIOutput.swift` — `Codable` structs for JSON output, `printResult()` / `printError()` functions
   - Create `OpenSuperMLX/CLI/CLIError.swift` — enum with all 12 error codes from spec, conforming to `Error`
   - Wire into `CLIRoot` global flags
4. Verify tests pass.
5. Verify: `lsp_diagnostics` clean.

**Files touched**: New `CLIOutput.swift`, `CLIError.swift`.

---

## Task 3: `transcribe` command

**Goal**: Batch file transcription through `TranscriptionService.transcribeAudio()`.

**TDD**:
1. Write test: `OpenSuperMLXTests/CLITests/TranscribeCommandTests.swift`
   - Test with bundled `test_audio.m4a` → produces non-empty text (integration, may need `XCTSkip` without model)
   - Test with non-existent file → error code `audio_file_not_found`
   - Test JSON output matches spec schema
   - Test `--no-correction` skips LLM step
2. Verify tests fail.
3. Implement:
   - `OpenSuperMLX/CLI/Commands/TranscribeCommand.swift`
   - Initialize `TranscriptionService` with lazy model loading (only load if command needs it)
   - Build `Settings` value type from CLI arguments
   - Call `TranscriptionService.transcribeAudio(url:settings:)`
   - Output via `CLIOutput`
4. Verify tests pass.
5. Verify: `lsp_diagnostics` clean.

---

## Task 4: `stream-simulate` command

**Goal**: Stream simulation via ring buffer injection into `StreamingAudioService`.

**TDD**:
1. Write test: `OpenSuperMLXTests/CLITests/StreamSimulateCommandTests.swift`
   - Test with bundled audio → produces non-empty text (integration)
   - Test `--chunk-duration` parameter parsing
   - Test JSON output includes `chunks_fed` and `intermediate_updates`
2. Write test: `OpenSuperMLXTests/StreamingAudioServiceFileInjectionTests.swift`
   - Test `injectAudioFromFile(url:chunkDuration:)` writes to ring buffer
   - Test 660ms tail padding is appended
   - Test file injection skips AVAudioEngine initialization
3. Verify tests fail.
4. Implement:
   - Add `injectAudioFromFile(url:chunkDuration:)` to `StreamingAudioService` — loads audio as `[Float]`, writes all chunks to ring buffer at full speed, appends 660ms silence. Does NOT call `setupAudioEngine()`.
   - `OpenSuperMLX/CLI/Commands/StreamSimulateCommand.swift` — calls the injection method, listens for events, 60s timeout
5. Verify tests pass.
6. Verify: `lsp_diagnostics` clean.

**Risk note from Momus**: `StreamingAudioService` is a critical 615-line singleton. The file injection method must be a **separate code path** that reuses ONLY the ring buffer, session creation, and task loop — not interleaving with the existing start/stop state machine.

---

## Task 5: `correct` command

**Goal**: Test LLM correction pipeline in isolation.

**TDD**:
1. Write test: `OpenSuperMLXTests/CLITests/CorrectCommandTests.swift`
   - Test with mock LLM provider → returns corrected text
   - Test `--provider` flag parsing
   - Test error handling when provider is not configured
2. Verify tests fail.
3. Implement `OpenSuperMLX/CLI/Commands/CorrectCommand.swift`.
4. Verify tests pass.
5. Verify: `lsp_diagnostics` clean.

---

## Task 6: `config` command

**Goal**: Read/write `AppPreferences` from CLI.

**TDD**:
1. Write test: `OpenSuperMLXTests/CLITests/ConfigCommandTests.swift`
   - Test `config list` outputs all keys with types and values
   - Test `config get mlxLanguage` returns current value
   - Test `config set mlxTemperature 0.5` writes Double correctly
   - Test `config set llmCorrectionEnabled true` writes Bool correctly
   - Test `config set` with invalid key → error `invalid_config_key`
   - Test `config set mlxTemperature abc` → error `invalid_config_value`
   - Use injectable `UserDefaults` (existing `AppPreferences.store` pattern)
2. Verify tests fail.
3. Implement `OpenSuperMLX/CLI/Commands/ConfigCommand.swift` with `list`, `get`, `set` subcommands.
4. Verify tests pass.

---

## Task 7: `recordings` command

**Goal**: CRUD operations on `RecordingStore`.

**TDD**:
1. Write test: `OpenSuperMLXTests/CLITests/RecordingsCommandTests.swift`
   - Use in-memory GRDB database (`RecordingStore(dbQueue:)`)
   - Test `list` with pagination
   - Test `search` matches transcription text
   - Test `show <id>` returns full details
   - Test `delete <id>` removes record
   - Test `regenerate <id>` with missing audio file → error `audio_file_missing`
2. Verify tests fail.
3. Implement `OpenSuperMLX/CLI/Commands/RecordingsCommand.swift` with 5 subcommands.
4. Verify tests pass.

---

## Task 8: `queue` command

**Goal**: Manage `TranscriptionQueue` from CLI.

**TDD**:
1. Write test: `OpenSuperMLXTests/CLITests/QueueCommandTests.swift`
   - Test `queue add` accepts multiple files
   - Test `queue status` reports pending/in-progress/completed counts
   - Test `queue add` with non-existent file → error
2. Verify tests fail.
3. Implement `OpenSuperMLX/CLI/Commands/QueueCommand.swift`.
4. Verify tests pass.

---

## Task 9: `mic` command

**Goal**: List and select audio input devices.

**TDD**:
1. Write test: `OpenSuperMLXTests/CLITests/MicCommandTests.swift`
   - Test `mic list` JSON output format
   - Test `mic select` with invalid device → error
   - Use `XCTSkip` on headless CI without audio devices
2. Verify tests fail.
3. Implement `OpenSuperMLX/CLI/Commands/MicCommand.swift`.
4. Verify tests pass.

---

## Task 10: `model` command

**Goal**: Model catalog management.

**TDD**:
1. Write test: `OpenSuperMLXTests/CLITests/ModelCommandTests.swift`
   - Test `model list` includes built-in and custom models
   - Test `model add <repo-id>` adds to custom models
   - Test `model remove <repo-id>` removes from custom models
   - Test `model select` with unknown model → error `model_not_found`
2. Verify tests fail.
3. Implement `OpenSuperMLX/CLI/Commands/ModelCommand.swift` with 5 subcommands.
4. Verify tests pass.

---

## Task 11: `benchmark` command

**Goal**: Accuracy (WER/CER), speed (RTF), and memory (`phys_footprint`) benchmarking.

**TDD**:
1. Write test: `OpenSuperMLXTests/CLITests/BenchmarkCommandTests.swift`
   - Test WER calculation: known input/reference pair → expected WER score
   - Test CER calculation: Chinese character-level comparison
   - Test RTF calculation: `processing_time / audio_duration`
   - Test `--wer-threshold` pass/fail logic
   - Test JSON output matches spec schema
2. Write test: `OpenSuperMLXTests/WERTests.swift`
   - Test vendored WER utilities against known examples
   - Test English normalization (numbers, punctuation)
   - Test CJK character splitting
3. Verify tests fail.
4. Implement:
   - Vendor WhisperKit's 4 WER files into `OpenSuperMLX/Utils/WER/`:
     - `DistanceCalculation.swift`
     - `WERUtils.swift`
     - `NormalizeEn.swift`
     - `SpellingMapping.swift`
   - Add CJK character splitting logic
   - Implement memory measurement using `task_info()` `phys_footprint`
   - Implement warm-up + N-trial timing loop
   - `OpenSuperMLX/CLI/Commands/BenchmarkCommand.swift`
   - Download and commit `jfk.wav` to test resources
5. Verify tests pass.

---

## Task 12: `diagnose` command

**Goal**: One-command environment snapshot.

**TDD**:
1. Write test: `OpenSuperMLXTests/CLITests/DiagnoseCommandTests.swift`
   - Test output includes macOS version, chip model
   - Test JSON output structure
2. Verify tests fail.
3. Implement `OpenSuperMLX/CLI/Commands/DiagnoseCommand.swift` — collects info from `ProcessInfo`, `MLXModelManager`, `MicrophoneService`, `PermissionsManager`.
4. Verify tests pass.

---

## Task 13: Mic hot-swap unit tests (protocol spy pattern)

**Goal**: Add protocol abstraction to `MicrophoneService` and write unit tests for device change handling.

**TDD**:
1. Write tests: `OpenSuperMLXTests/MicHotSwapTests.swift`
   - Test device disappears → falls back to built-in mic
   - Test `AVAudioEngineConfigurationChange` notification → engine restarts
   - Test configured device not in device list → graceful fallback
   - Test rapid successive device changes → no crash
2. Verify tests fail.
3. Implement:
   - Extract `AudioDeviceChangeObserver` protocol from `MicrophoneService`
   - Add injectable `isDeviceAlive: ((AudioDeviceID) -> Bool)?` closure
   - Create `AudioDeviceChangeObserverSpy` test double
4. Verify tests pass.

---

## Task 14: Code simplification

**Goal**: Review all new code for clarity, consistency, and adherence to project conventions.

- Review all files in `OpenSuperMLX/CLI/` for: naming conventions, access control, comment policy, import ordering
- Ensure no `as any`, `@ts-ignore` equivalents, empty catch blocks
- Verify consistent use of `Logger` (not `print()`)
- Remove any dead code or unused imports

---

## Task 15: Final build and test verification

**Goal**: Full end-to-end validation.

```bash
# Full build
./run.sh build

# All unit tests
xcodebuild test -scheme OpenSuperMLX -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build -clonedSourcePackagesDirPath SourcePackages \
  CODE_SIGNING_ALLOWED=NO -only-testing:OpenSuperMLXTests

# Smoke test CLI commands
./build/Build/Products/Debug/OpenSuperMLX diagnose --json
./build/Build/Products/Debug/OpenSuperMLX config list --json
./build/Build/Products/Debug/OpenSuperMLX model list --json
```

- All tests pass
- Build succeeds
- CLI smoke tests produce valid JSON
- No regressions in existing tests

---

## Worktree Cleanup

After PR merges:
```bash
git worktree remove ../OpenSuperMLX-cli-test-harness
```
