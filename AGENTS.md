# AGENTS.md — OpenSuperMLX

macOS menu-bar app for real-time audio transcription using MLX on Apple Silicon.
Swift 5 / SwiftUI, Xcode project, targeting macOS 14.0+ (Sonoma), ARM64 only.

## Build Commands

```bash
# Prerequisites
brew install cmake libomp rust ruby && gem install xcpretty
git submodule update --init --recursive

# Full build (Rust dylib + WeTextProcessing + patches + Xcode)
./run.sh build

# Build and run
./run.sh
```

### Fast Incremental Build (~3-5 seconds)

For **Swift-only changes**, skip `run.sh` — the **preferred build command during development**:

```bash
xcodebuild -scheme OpenSuperMLX -configuration Debug -jobs 8 \
  -derivedDataPath build -quiet -destination 'platform=macOS,arch=arm64' \
  -skipPackagePluginValidation -skipMacroValidation \
  -clonedSourcePackagesDirPath SourcePackages CODE_SIGNING_ALLOWED=NO build
```

**Fall back to `./run.sh build`** when: first build on fresh clone, after modifying `asian-autocorrect/` (Rust), `patches/*.patch`, `WeTextProcessing/` (ITN binary), SPM dependencies, or if `build/` was deleted.

**`VendoredPackages/mlx-audio-swift/`** — edit Swift source directly; changes are picked up by the incremental xcodebuild above (no `./run.sh` needed).

## Tests

```bash
# All unit tests
xcodebuild test -scheme OpenSuperMLX -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build -clonedSourcePackagesDirPath SourcePackages \
  CODE_SIGNING_ALLOWED=NO -only-testing:OpenSuperMLXTests

# Single test class
xcodebuild test -scheme OpenSuperMLX -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build -clonedSourcePackagesDirPath SourcePackages \
  CODE_SIGNING_ALLOWED=NO -only-testing:OpenSuperMLXTests/ITNProcessorTests

# Single test method
xcodebuild test -scheme OpenSuperMLX -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build -clonedSourcePackagesDirPath SourcePackages \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:OpenSuperMLXTests/ITNProcessorTests/testCleanDuplicateChinesePunctuation
```

`ClipboardUtilPasteIntegrationTests` require accessibility permissions and an active display — they `XCTSkip` when unavailable.

## CLI Test Harness

The binary doubles as a CLI test harness. When launched with a subcommand it runs headlessly; with no subcommand it launches the GUI as usual.

```bash
# Binary location after build
BINARY=build/Build/Products/Debug/OpenSuperMLX.app/Contents/MacOS/OpenSuperMLX
```

### Available Commands

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

### Global Flags

All commands accept these flags **after** the subcommand name:

- `--json` — structured JSON output to stdout (default: human-readable)
- `--quiet` — suppress progress/status on stderr
- `--verbose` — detailed logging on stderr

### Output Convention

- **stdout**: final result only (text or JSON) — safe to pipe to `jq` or capture in scripts
- **stderr**: progress, logs, diagnostics
- **Exit codes**: `0` success, `1` runtime failure, `64` bad arguments

### Running CLI Tests

```bash
# All CLI command tests
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

# Single CLI command test class
xcodebuild test -scheme OpenSuperMLX -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build -clonedSourcePackagesDirPath SourcePackages \
  CODE_SIGNING_ALLOWED=NO -only-testing:OpenSuperMLXTests/ConfigCommandTests

# Smoke test (quick sanity check after build)
$BINARY diagnose --json 2>/dev/null | python3 -m json.tool
$BINARY config list --json 2>/dev/null | python3 -m json.tool
$BINARY model list --json 2>/dev/null | python3 -m json.tool
```

### Error Codes (JSON `error.code` field)

`model_not_found`, `model_not_cached`, `model_load_failed`, `audio_file_not_found`, `audio_format_unsupported`, `transcription_failed`, `stream_timeout`, `llm_correction_failed`, `database_error`, `audio_file_missing`, `invalid_config_key`, `invalid_config_value`

## Patches

`run.sh` applies `patches/*.patch` to SPM checkouts on every build (idempotent via `patch -N`). `mlx-audio-swift` is vendored at `VendoredPackages/mlx-audio-swift/` — modify its source directly instead of using patches.

## Project Structure

```
OpenSuperMLX/                    # Main app target
├── main.swift                   # Entry point: CLI (--transcribe) or GUI
├── CLITranscribe.swift          # CLI transcription mode
├── OpenSuperMLXApp.swift        # AppState, AppDelegate, menu bar
├── ContentView.swift            # Main UI (recording list, search, mic picker)
├── Settings.swift               # Settings UI + SettingsViewModel + Settings value type
├── AudioRecorder.swift          # AVAudioRecorder/Player wrapper (singleton)
├── StreamingAudioService.swift  # Real-time streaming via AVAudioEngine (singleton)
├── TranscriptionService.swift   # Transcription orchestration (singleton)
├── TranscriptionQueue.swift     # File queue processing (singleton)
├── MLXModelManager.swift        # Model catalog + custom model management
├── MicrophoneService.swift      # Audio device enumeration, selection, CoreAudio
├── ShortcutManager.swift        # Global hotkey handling + hold-to-record
├── FileDropHandler.swift        # Drag-and-drop audio file import
├── PermissionsManager.swift     # Microphone + accessibility permission checks
├── Engines/
│   ├── TranscriptionEngine.swift  # Protocol definition
│   └── MLXEngine.swift            # MLX-based implementation
├── CLI/
│   ├── CLIRoot.swift              # Root ParsableCommand + GlobalOptions + runAsync helper
│   ├── CLIOutput.swift            # JSON/text output formatting, stdout/stderr separation
│   ├── CLIError.swift             # 12 enumerated error codes
│   └── Commands/                  # 10 subcommand implementations
│       ├── TranscribeCommand.swift
│       ├── StreamSimulateCommand.swift
│       ├── CorrectCommand.swift
│       ├── ConfigCommand.swift
│       ├── RecordingsCommand.swift
│       ├── QueueCommand.swift
│       ├── MicCommand.swift
│       ├── ModelCommand.swift
│       ├── BenchmarkCommand.swift
│       └── DiagnoseCommand.swift
├── Services/
│   ├── AudioMixer.swift           # Multi-source audio mixing
│   ├── BedrockLLMProvider.swift   # AWS Bedrock LLM provider
│   ├── LLMCorrectionService.swift # Post-transcription LLM correction
│   ├── LLMProvider.swift          # LLM provider protocol
│   ├── OpenAICompatibleLLMProvider.swift # OpenAI-compatible LLM provider
│   └── SystemAudioService.swift   # System audio capture
├── Models/
│   └── Recording.swift          # Recording model + RecordingStore (GRDB)
├── Indicator/                   # Floating mini-recorder overlay
├── Onboarding/                  # First-launch onboarding flow
├── Utils/
│   ├── AppPreferences.swift     # UserDefaults wrappers (@UserDefault, @OptionalUserDefault)
│   ├── AutocorrectWrapper.swift # Bridge to Rust autocorrect dylib
│   ├── ClipboardUtil.swift      # Paste-via-CGEvent, keyboard layout detection
│   ├── DevConfig.swift          # #if DEBUG toggles
│   ├── FocusUtils.swift         # Accessibility API caret/cursor position
│   ├── ITNProcessor.swift       # Chinese inverse text normalization (WeTextProcessing)
│   ├── KeyboardLayoutProvider.swift # Keyboard layout detection for paste routing
│   ├── LanguageUtil.swift       # Language code ↔ display name mapping
│   ├── NemoTextProcessing.swift # English inverse text normalization (text-processing-rs)
│   ├── NotificationName+App.swift  # Typed Notification.Name extensions
│   ├── RepetitionCleaner.swift  # Remove repeated text from transcription output
│   └── RMSNormalizer.swift      # Audio RMS level normalization
├── Bridge.h                     # Bridging header (autocorrect + text-processing-rs)
OpenSuperMLXTests/               # Hosted tests (XCTest) — majority of unit + integration tests
OpenSuperMLXUnitTests/           # Hostless tests (streaming inference, no host app)
OpenSuperMLXUITests/             # UI tests
asian-autocorrect/               # Git submodule — Rust autocorrect library
text-processing-rs/              # Git submodule — Rust English ITN library (NeMo port)
patches/                         # Patches applied to SPM checkouts by run.sh
Scripts/                         # Utility scripts (keyboard layout mgmt, patch resolution)
Resources/ITN/                   # ITN binary resources
VendoredPackages/
└── mlx-audio-swift/             # MLX Audio library (MLXAudioCore, MLXAudioCodecs, MLXAudioSTT)
docs/                            # See [Reference Docs](#reference-docs) for when to consult each
```

## Dependencies

- **SPM**: GRDB.swift, KeyboardShortcuts, AWSBedrockRuntime, ArgumentParser
- **Vendored**: mlx-audio-swift at `VendoredPackages/mlx-audio-swift/`
- **System frameworks**: Metal, Accelerate, AVFoundation, CoreAudio, ApplicationServices, Carbon
- **Git submodules**: `asian-autocorrect` (Rust autocorrect dylib), `text-processing-rs` (Rust English ITN dylib) — both bridged through `Bridge.h`; `WeTextProcessing` (C++ Chinese ITN processor, built via cmake)

## Code Style

### Formatting & Imports

- 4-space indentation, opening braces on same line, one blank line between methods
- No SwiftLint/SwiftFormat — follow existing patterns
- Apple frameworks first, then third-party, alphabetical within each group:
  ```swift
  import AVFoundation
  import Foundation
  import SwiftUI

  import GRDB
  import KeyboardShortcuts
  ```

### Comments and Documentation

**Default: no comments.** Code should be self-documenting through clear naming.

- **`///` doc comments**: Only on non-obvious public API properties/methods in `VendoredPackages/` or protocol definitions. Do not add them to app-layer code where the name is self-explanatory.
- **Inline `//` comments**: Only for complex algorithms, regex, performance-critical math, or non-obvious security decisions. Never to explain *what* the code does — only *why* it does something unexpected.
- **`// MARK: -`**: Use to organize sections within files (required for files > ~80 lines).
- **Never** add "memo-style" comments describing what you changed, or restating what the next line does.

### Naming

- **Types**: `PascalCase` — `TranscriptionService`, `MLXEngine`
- **Variables/functions**: `camelCase` — `isRecording`, `startDecoding()`
- **Enum cases**: `camelCase` — `.pending`, `.contextInitializationFailed`
- **Files**: Match primary type name; extensions use `TypeName+Category.swift`

### Architecture

- **Singletons**: `static let shared = ClassName()` with `private init()`
- **MVVM**: `@StateObject` ViewModels with `ObservableObject`
- **Protocol abstraction**: `TranscriptionEngine` protocol, `MLXEngine` implementation
- **Communication**: `NotificationCenter` with typed `Notification.Name` extensions
- **Recording flow**: ShortcutManager → IndicatorViewModel.startRecording() → StreamingAudioService or AudioRecorder

### Concurrency

- `@MainActor` on UI-touching classes (`TranscriptionService`, `TranscriptionQueue`, `RecordingStore`)
- `Task.detached(priority: .userInitiated)` for heavy work off main thread
- `nonisolated` for methods callable from any actor
- `OSAllocatedUnfairLock` for thread-safe shared state (see `StreamingAudioService.ringBuffer`)
- Prefer Swift concurrency (`async/await`) over GCD for new code

### Error Handling

- Custom error enums: `enum TranscriptionError: Error { case ... }`
- `Logger(subsystem: "OpenSuperMLX", category: "...")` for structured logging
- Never use `print()` — it doesn't appear in unified logs for GUI apps
- `fatalError()` only for truly unrecoverable failures
- `try?` for optional file operations; `guard let ... else { return }` for early exits
- For debugging methodology and Logger usage details, see [Reference Docs](#reference-docs) below

### Access Control

- `private` for implementation details and singleton `init()`
- `private(set)` for published read-only state: `@Published private(set) var isTranscribing`
- Default (internal) for most properties and methods

### SwiftUI

- `@StateObject` for owned VMs, `@ObservedObject` for passed-in
- `ThemePalette` static methods for consistent theming
- `.buttonStyle(.plain)` + `.help("tooltip")` on interactive elements

### Data Layer

- **GRDB** for SQLite: `FetchableRecord`/`PersistableRecord`, `DatabaseMigrator` with versioned migrations
- **UserDefaults** via `@UserDefault` / `@OptionalUserDefault` property wrappers in `AppPreferences`

### Testing

- `final class ... : XCTestCase`, methods: `func testDescriptiveName() throws`
- `XCTSkip` for environment-dependent tests (keyboard layouts, hardware)
- Sections organized with `// MARK: -`; test data: `test_audio.m4a` in test bundle

## Debugging (MANDATORY)

When investigating bugs, you MUST read [`docs/debugging.md`](docs/debugging.md) before proposing any fix — it covers the CLI-first reproduction strategy and diagnostic logging techniques required for all investigations.

## Test Requirements (MANDATORY)

### What MUST Be Tested

- Public API behavior: every non-trivial public/internal method that contains logic
- Edge cases: empty input, nil/optional values, boundary conditions, error paths
- Regression tests for every bug fix: the test must fail before the fix and pass after
- Integration seams between modules: e.g., ITNProcessor output fed into transcription pipeline

### What MUST NOT Be Tested

- SwiftUI views: layout, rendering, animations — these are untestable in unit tests
- Trivial getters and setters with no logic
- Animations, transitions, and visual states
- UI layout or view hierarchy

### Test Patterns by Change Type

- **Utility/helper function**: write input/output pair tests covering the happy path and at least one edge case
- **Service class**: mock all dependencies, test orchestration logic in isolation — never instantiate real singletons
- **Bug fix**: write a regression test that reproduces the bug before the fix is applied, then verify it passes after
- **Settings/config**: use the Settings value type directly with an injectable initializer — do not read from live UserDefaults

### Test Rules

1. Every new source file MUST have a corresponding test file in `OpenSuperMLXTests/`
2. No real model loading in tests — use protocol mocks or `XCTSkip` if a real model is unavoidable
3. No real audio hardware in unit tests — mock `AVAudioEngine`/`AVAudioRecorder` or use bundled test fixtures
4. One test file per source file: `FooTests.swift` tests `Foo.swift`, nothing else
5. 3-8 test methods per test class — focus on core value; do not pad with trivial assertions
6. All tests MUST pass in CI — no flaky tests; use `XCTSkip` for anything that requires hardware, accessibility permissions, or an active display

### Other Conventions

- `#if DEBUG ... #endif` for debug-only code (see `DevConfig.swift`)
- File headers: `// FileName.swift // OpenSuperMLX // Created by ...`

### Pre-Commit CLI Verification (MANDATORY)

Before committing any feature or bug fix that touches transcription, streaming, settings, recording, model, or audio pipeline code, you MUST verify the change via CLI. This is not optional — UI-only testing is insufficient because UI bugs are hard to reproduce.

**Rule: If a CLI command can exercise the code path you changed, run it before committing.**

| What you changed | CLI verification required |
|---|---|
| Transcription logic, model loading, ITN, autocorrect | `transcribe <test-audio> --json` — verify output text is correct |
| Streaming pipeline, ring buffer, feedTask, events | `stream-simulate <test-audio> --json` — verify streaming produces text |
| LLM correction, provider config | `correct "test text" --json` — verify correction runs |
| AppPreferences, settings, defaults | `config get <key>` / `config set <key> <value>` — verify read/write |
| RecordingStore, database migrations | `recordings list --json` — verify DB operations work |
| TranscriptionQueue, file processing | `queue status --json` — verify queue state |
| MicrophoneService, device handling | `mic list --json` — verify device enumeration |
| MLXModelManager, model catalog | `model list --json` — verify catalog |
| Any change at all (minimum bar) | `diagnose --json` — verify environment snapshot still works |

**Workflow:**
1. Make your code change
2. Run the relevant CLI command(s) from the table above
3. Verify the JSON output is valid and correct
4. Run the relevant unit tests (`-only-testing:OpenSuperMLXTests/<TestClass>`)
5. Only then commit

**For bug fixes:** reproduce the bug via CLI first, fix, then verify the fix via the same CLI command. Include the CLI reproduction steps in the commit message.

## CI

GitHub Actions on `master` branch and PRs (`.github/workflows/build.yml`):

1. `./run.sh build` — full build
2. Unit tests (hostless): `-only-testing:OpenSuperMLXUnitTests`
3. Integration tests (hosted): `-only-testing:OpenSuperMLXTests` with skips: `BenchmarkTests`, `JapaneseGarblingRegressionTests`, `MicrophoneInventoryTests`, `KeyboardLayoutProviderTests`

The default test plan (`OpenSuperMLX.xctestplan`) passes `--skip-model-load` and skips `BenchmarkTests` + `JapaneseGarblingRegressionTests`. Separate `OpenSuperMLXBenchmarks.xctestplan` exists for benchmark runs.

`.github/workflows/release.yml` handles tagged releases (`X.Y.Z` format) with dedicated build steps for each native library, Release xcodebuild, DMG creation, and Homebrew tap update.

## Plan Conventions

When creating work plans (`.sisyphus/plans/*.md`), every plan MUST include:

1. **Code Simplifier Task** — Code simplification.

### Build Verification Strategy

Individual tasks within a plan MUST NOT run full project builds (`xcodebuild build` / `./run.sh build`) for verification — builds are expensive and time-consuming. Instead:

- **During task execution**: Use `lsp_diagnostics` to catch compile errors in changed files. Run only the relevant unit tests (`-only-testing:`) for the code being modified.
- **After all tasks complete**: Run a single full build and full test suite as the final verification step of the plan.

Plans MUST include a dedicated final task for this end-to-end build and test verification.

### TDD Requirement (MANDATORY)

All plans MUST follow **Test-Driven Development (TDD)** — plans that list implementation before corresponding tests are invalid. For every feature or behavior change:

1. **Write tests first** — Add or update tests that describe the expected behavior BEFORE writing implementation code.
2. **Verify tests fail** — Run the new tests to confirm they fail (red phase). This proves the tests are actually validating new behavior.
3. **Implement minimally** — Write the minimum production code needed to make the failing tests pass (green phase).
4. **Refactor** — Clean up implementation while keeping tests green.

### Work Tree Requirement (MANDATORY)

All plan execution MUST happen in a dedicated `git worktree` — never directly in the main working tree.

```bash
# Create worktree + feature branch for the plan
git worktree add ../OpenSuperMLX-<plan-name> -b <branch-name>

# All implementation happens inside the worktree
# After PR merge, clean up
git worktree remove ../OpenSuperMLX-<plan-name>
```

- Worktree path: sibling of project root (`../OpenSuperMLX-<plan-name>`)
- One feature branch per plan, created at worktree add time
- Main working tree stays clean for reviews, hotfixes, and ad-hoc work
- Remove worktree after the plan's PR merges

## Reference Docs

| File | When to consult |
|---|---|
| [`docs/debugging.md`](docs/debugging.md) | **Investigating any bug or unexpected behavior.** Read before proposing fixes — covers CLI-first repro strategy and Logger-based tracing. |
| [`docs/logging.md`](docs/logging.md) | **Adding or reading Logger statements.** Covers `os.Logger` setup, privacy annotations, and `log stream` / `log show` commands. |
| [`docs/learnings.md`](docs/learnings.md) | **Before any release, or when touching native libraries.** Past mistakes and the New Native Library Checklist. |
| [`docs/memory.md`](docs/memory.md) | **Profiling memory or touching streaming pipeline.** MLX GPU memory budget, encoder dtype, streaming memory invariants, and red flags for memory regressions. |
| [`docs/release_build.md`](docs/release_build.md) | **Building a release.** Notarization command (`notarize_app.sh`). |

## Release

```bash
./make_release.sh <version> "<code_sign_identity>" [github_token]
# Notarize only:
./notarize_app.sh "<code_sign_identity>"
```

**Before any release**, consult [`docs/learnings.md`](docs/learnings.md) — especially the **New Native Library Checklist** if any native libraries were added or modified since the last release. See [Reference Docs](#reference-docs).

## Skill routing

When the user's request matches an available skill, ALWAYS invoke it using the Skill
tool as your FIRST action. Do NOT answer directly, do NOT use other tools first.
The skill has specialized workflows that produce better results than ad-hoc answers.

Key routing rules:
- Product ideas, "is this worth building", brainstorming → invoke office-hours
- Bugs, errors, "why is this broken", 500 errors → invoke investigate
- Ship, deploy, push, create PR → invoke ship
- QA, test the site, find bugs → invoke qa
- Code review, check my diff → invoke review
- Update docs after shipping → invoke document-release
- Weekly retro → invoke retro
- Design system, brand → invoke design-consultation
- Visual audit, design polish → invoke design-review
- Architecture review → invoke plan-eng-review
- Save progress, checkpoint, resume → invoke checkpoint
- Code quality, health check → invoke health
