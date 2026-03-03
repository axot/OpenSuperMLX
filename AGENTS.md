# AGENTS.md — OpenSuperMLX

## Project Overview

macOS menu-bar app for real-time audio transcription using MLX on Apple Silicon.
Swift 5 / SwiftUI, Xcode project, targeting macOS 14.0+ (Sonoma), ARM64 only.

## Build Commands

### Prerequisites

```bash
brew install cmake libomp rust ruby
gem install xcpretty
git submodule update --init --recursive
```

### Build (full pipeline — Rust dylib + Xcode)

```bash
./run.sh build
```

This builds the Rust `autocorrect-swift` dylib via Cargo, copies required dylibs to `build/`,
then runs `xcodebuild` for the `OpenSuperMLX` scheme in Debug configuration.

### Build and Run

```bash
./run.sh
```

### Xcode Build (direct — after dylibs are in build/)

```bash
xcodebuild -scheme OpenSuperMLX -configuration Debug -jobs 8 \
  -derivedDataPath build -quiet -destination 'platform=macOS,arch=arm64' \
  -skipPackagePluginValidation -skipMacroValidation \
  -clonedSourcePackagesDirPath SourcePackages \
  CODE_SIGNING_ALLOWED=NO build
```

### Tests

```bash
# All unit tests
xcodebuild test -scheme OpenSuperMLX -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build -clonedSourcePackagesDirPath SourcePackages \
  CODE_SIGNING_ALLOWED=NO -only-testing:OpenSuperMLXTests

# Single test class
xcodebuild test -scheme OpenSuperMLX -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build -clonedSourcePackagesDirPath SourcePackages \
  CODE_SIGNING_ALLOWED=NO -only-testing:OpenSuperMLXTests/MicrophoneServiceBluetoothTests

# Single test method
xcodebuild test -scheme OpenSuperMLX -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build -clonedSourcePackagesDirPath SourcePackages \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:OpenSuperMLXTests/MicrophoneServiceBluetoothTests/testBluetoothDetection_BluetoothInName
```

Note: Many tests in `ClipboardUtilPasteIntegrationTests` require accessibility permissions
and an active display. They will `XCTSkip` when keyboard layouts are unavailable.

### Release

```bash
./make_release.sh <version> "<code_sign_identity>" [github_token]
```

### CI

GitHub Actions workflow: `.github/workflows/build.yml` — runs `./run.sh build` on `macos-latest`.

## Project Structure

```
OpenSuperMLX/              # Main app target
├── OpenSuperMLXApp.swift  # @main App entry point, AppState, AppDelegate
├── ContentView.swift      # Main UI (recording list, search, controls)
├── Settings.swift         # Settings UI + SettingsViewModel + Settings value type
├── AudioRecorder.swift    # AVAudioRecorder/Player wrapper (singleton)
├── TranscriptionService.swift  # Transcription orchestration (singleton)
├── TranscriptionQueue.swift    # File queue processing (singleton)
├── MLXModelManager.swift  # Model catalog + custom model management
├── ShortcutManager.swift  # Global keyboard shortcut handling
├── MicrophoneService.swift     # Audio device enumeration + selection
├── ModifierKeyMonitor.swift    # Single-modifier-key detection
├── PermissionsManager.swift    # Mic + accessibility permission checks
├── FileDropHandler.swift  # Drag-and-drop audio file handling
├── Engines/
│   ├── TranscriptionEngine.swift  # Protocol definition
│   └── MLXEngine.swift            # MLX-based implementation
├── Models/
│   └── Recording.swift    # Recording model + RecordingStore (GRDB)
├── Indicator/             # Floating mini-recorder overlay
├── Onboarding/            # First-launch onboarding flow
├── Utils/
│   ├── AppPreferences.swift      # UserDefaults wrappers
│   ├── AutocorrectWrapper.swift  # C FFI bridge to autocorrect lib
│   ├── ClipboardUtil.swift       # Pasteboard + simulated Cmd+V
│   ├── DevConfig.swift           # DEBUG-only dev config from JSON
│   ├── FocusUtils.swift          # Window focus utilities
│   ├── KeyboardLayoutProvider.swift  # Keyboard layout detection
│   ├── LanguageUtil.swift        # Language code/name mappings
│   └── NotificationName+App.swift    # Custom Notification.Name constants
├── Bridge.h               # Bridging header for autocorrect C library
OpenSuperMLXTests/         # Unit tests (XCTest)
OpenSuperMLXUITests/       # UI tests (XCUITest)
asian-autocorrect/         # Git submodule — Rust autocorrect library
```

## Dependencies

- **SPM**: GRDB.swift (SQLite ORM), KeyboardShortcuts, MLX/MLXAudioSTT/MLXAudioCore, HuggingFace
- **System frameworks**: Metal, MetalKit, Accelerate, AVFoundation, ApplicationServices, Carbon
- **Git submodule**: `asian-autocorrect` (Rust → dylib via Cargo, bridged through `Bridge.h`)
- **Homebrew**: cmake, libomp, rust

## Code Style

### Formatting

- 4-space indentation (Xcode default)
- No SwiftLint or SwiftFormat configured — follow existing patterns
- Opening braces on same line: `func foo() {`
- One blank line between method definitions
- File header comments: `// FileName.swift // OpenSuperMLX // Created by ...`

### Imports

Apple frameworks first, then third-party, alphabetical within each group:

```swift
import AVFoundation
import Foundation
import SwiftUI

import KeyboardShortcuts
import GRDB
```

### Naming

- **Types**: `PascalCase` — `TranscriptionService`, `RecordingStatus`, `MLXEngine`
- **Variables/functions**: `camelCase` — `isRecording`, `startDecoding()`
- **Constants**: `camelCase` — `static let shared`, `let pageSize = 100`
- **Enum cases**: `camelCase` — `.pending`, `.contextInitializationFailed`
- **Protocols**: Noun or adjective — `TranscriptionEngine`, `Identifiable`
- **Files**: Match primary type name — `TranscriptionService.swift`
- **Extensions in separate files**: `TypeName+Category.swift` (e.g. `NotificationName+App.swift`)

### Architecture Patterns

- **Singletons**: `static let shared = ClassName()` with `private init()`
- **MVVM**: `@StateObject` ViewModels (`ContentViewModel`, `SettingsViewModel`) with `ObservableObject`
- **Protocol abstraction**: `TranscriptionEngine` protocol, `MLXEngine` implementation
- **Notification-based communication**: `NotificationCenter` with typed `Notification.Name` extensions
- **Reactive binding**: Combine `$published` sinks with `AnyCancellable` sets

### Concurrency

- `@MainActor` on classes that touch UI: `TranscriptionService`, `TranscriptionQueue`, `RecordingStore`
- `Task { @MainActor in ... }` for dispatching to main actor from detached contexts
- `Task.detached(priority: .userInitiated)` for heavy work off main thread
- `nonisolated` on methods that must be called from any actor context
- `DispatchQueue.main.async` used in older patterns (e.g. `AudioRecorder`)
- Prefer Swift concurrency (`async/await`) over GCD for new code

### Error Handling

- Custom error enums: `enum TranscriptionError: Error { case ... }`
- `print()` for non-critical errors (file operations, audio playback)
- `os.log` Logger for structured logging in service classes:
  ```swift
  private let logger = Logger(subsystem: "OpenSuperMLX", category: "MLXEngine")
  ```
- `fatalError()` only for truly unrecoverable initialization failures (database setup)
- `try?` for optional file operations where failure is acceptable
- `guard let ... else { return }` pattern for early exits

### Access Control

- `private` for internal implementation details and `init()` on singletons
- Default (internal) for most properties and methods
- `private(set)` for published read-only state: `@Published private(set) var isTranscribing`
- `static` for singleton instances and shared constants
- `final class` for test classes and leaf classes

### SwiftUI Conventions

- `@StateObject` for owned view models, `@ObservedObject` for passed-in ones
- `@Environment(\.colorScheme)` for theme-aware colors
- `ThemePalette` static methods for consistent theming
- Computed properties for derived view state (`var isPending: Bool`)
- `.buttonStyle(.plain)` + `.help("tooltip")` on interactive elements

### Data Layer

- **GRDB** for SQLite persistence: `FetchableRecord`, `PersistableRecord` conformance
- `DatabaseMigrator` with versioned migrations (`v1`, `v2_add_status`)
- `CodingKeys` enum for explicit column mapping
- `Column()` typed column references in a nested `Columns` enum
- **UserDefaults** via custom `@UserDefault` / `@OptionalUserDefault` property wrappers

### Testing

- XCTest framework, test classes are `final class ... : XCTestCase`
- Test methods: `func testDescriptiveName() throws`
- `XCTSkip` for environment-dependent tests (keyboard layouts, hardware)
- `setUpWithError()` / `tearDownWithError()` for setup/cleanup
- Tests colocated in single file grouped by `// MARK: -` sections
- Test data: `test_audio.m4a` in test bundle

### MARK Comments

Use `// MARK: -` to organize code sections within files:

```swift
// MARK: - Singleton Instance
// MARK: - Private
// MARK: - Keyboard Layout Tests
```

### #if DEBUG

Wrap debug-only code in `#if DEBUG ... #endif` (see `DevConfig.swift`, `AppState.init`).
