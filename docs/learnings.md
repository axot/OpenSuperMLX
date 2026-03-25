# Learnings

Consult before introducing native libraries, modifying build pipelines, or making releases.

## New Native Library Checklist

**When adding a new native library (dylib/binary) to the project, ALL of the following build scripts must be updated. Missing any one causes the release build to fail or the app to crash at runtime.**

| Build Script | Purpose | What to Add |
|---|---|---|
| `run.sh` | Local dev build | cargo build + cp + install_name_tool + codesign (ad-hoc `--sign -`) |
| `notarize_app.sh` | Local release signing & notarization | cargo build + cp + install_name_tool + codesign (real identity `${CODE_SIGN_IDENTITY}` + `--timestamp`) |
| `.github/workflows/release.yml` | GitHub Actions tagged release | Separate step with cargo build + cp + install_name_tool + codesign |
| `OpenSuperMLX.xcodeproj/project.pbxproj` | Xcode project | PBXFileReference + PBXBuildFile (Frameworks) + PBXBuildFile (CopyFiles with CodeSignOnCopy) |
| `Bridge.h` | C FFI bridging header | `#include` for the library's C header |

### Incident: WeTextProcessing (2025)

Added `processor_main` binary and FST files to `run.sh` and `release.yml` but forgot to add the copy step to `notarize_app.sh`. Result: the signed release build was missing `processor_main`, causing Chinese ITN to silently fail at runtime.

### Incident: text-processing-rs (2025)

Added `libtext_processing_rs.dylib` to `run.sh` and `release.yml` but initially missed `notarize_app.sh`. Caught during pre-release review before any release was shipped.

### Key Difference Between Build Scripts

- **`run.sh`**: Uses ad-hoc signing (`--sign -`) — fine for local development
- **`notarize_app.sh`**: Uses real Developer ID (`${CODE_SIGN_IDENTITY}` + `--timestamp`) — required for notarization and distribution
- **`release.yml`**: Uses ad-hoc signing on CI (GitHub Actions doesn't have signing identity) — the Xcode build step handles final signing

Forgetting the signing difference will cause notarization to fail even if the library is present.
