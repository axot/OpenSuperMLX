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

## Patches

`run.sh` applies `patches/*.patch` to SPM checkouts on every build (idempotent via `patch -N`). `mlx-audio-swift` is vendored at `VendoredPackages/mlx-audio-swift/` — modify its source directly instead of using patches.

## Project Structure

```
OpenSuperMLX/                    # Main app target
├── OpenSuperMLXApp.swift        # @main entry, AppState, AppDelegate, menu bar
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
├── Services/
│   └── BedrockService.swift       # AWS Bedrock LLM post-transcription correction
├── Models/
│   └── Recording.swift          # Recording model + RecordingStore (GRDB)
├── Indicator/                   # Floating mini-recorder overlay
├── Onboarding/                  # First-launch onboarding flow
├── Utils/
│   ├── AppPreferences.swift     # UserDefaults wrappers (@UserDefault, @OptionalUserDefault)
│   ├── ClipboardUtil.swift      # Paste-via-CGEvent, keyboard layout detection
│   ├── AutocorrectWrapper.swift # Bridge to Rust autocorrect dylib
│   ├── ITNProcessor.swift       # Chinese inverse text normalization (WeTextProcessing)
│   ├── DevConfig.swift          # #if DEBUG toggles
│   ├── FocusUtils.swift         # Accessibility API caret/cursor position
│   ├── LanguageUtil.swift       # Language code ↔ display name mapping
│   └── NotificationName+App.swift  # Typed Notification.Name extensions
├── Bridge.h                     # Bridging header for autocorrect C library
OpenSuperMLXTests/               # Unit tests (XCTest)
asian-autocorrect/               # Git submodule — Rust autocorrect library
patches/                         # Patches applied to SPM checkouts by run.sh
VendoredPackages/
└── mlx-audio-swift/             # MLX Audio library (MLXAudioCore, MLXAudioCodecs, MLXAudioSTT)
docs/
└── logging.md                   # Logger usage guide and log reading commands
```

## Dependencies

- **SPM**: GRDB.swift, KeyboardShortcuts, AWSBedrockRuntime
- **Vendored**: mlx-audio-swift at `VendoredPackages/mlx-audio-swift/`
- **System frameworks**: Metal, Accelerate, AVFoundation, CoreAudio, ApplicationServices, Carbon
- **Git submodule**: `asian-autocorrect` (Rust → dylib via Cargo, bridged through `Bridge.h`)

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
- `Logger(subsystem: "OpenSuperMLX", category: "...")` for structured logging — see [`docs/logging.md`](docs/logging.md)
- Never use `print()` — it doesn't appear in unified logs for GUI apps
- `fatalError()` only for truly unrecoverable failures
- `try?` for optional file operations; `guard let ... else { return }` for early exits

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

### Other Conventions

- `#if DEBUG ... #endif` for debug-only code (see `DevConfig.swift`)
- File headers: `// FileName.swift // OpenSuperMLX // Created by ...`

## CI

GitHub Actions: `.github/workflows/build.yml` runs `./run.sh build` on `macos-latest` for pushes and PRs. `.github/workflows/release.yml` handles tagged releases and includes a WeTextProcessing build step to produce `processor_main` before the Xcode build.

## Plan Conventions

When creating work plans (`.sisyphus/plans/*.md`), every plan MUST include:

1. **Oracle Review Task** — Architecture and code review by Oracle agent after all implementation tasks complete.
2. **Code Simplifier Task** — Code simplification pass AFTER Oracle review (sequential, not parallel).

**Execution order**: Oracle review → Code Simplifier (always sequential, never parallel).

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

## Release

```bash
./make_release.sh <version> "<code_sign_identity>" [github_token]
```
