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

## MLX Streaming Memory — Lessons from a 12 GB Leak (2026-04)

A 21-minute audio transcription caused MLX peak memory to grow from 3.9 GB to 12.3 GB. Root cause was three interacting issues in `ContinuousChunkProcessor`. All three must be addressed together — fixing only one or two is insufficient.

### Lesson 1: Truncate accumulated state on periodic reset

The mel spectrogram buffer (`accumulatedMel`) grew unboundedly across reset cycles. `reset(keepEmittedTokens: true)` preserved the full buffer, so every reset rebuilt the KV cache from the entire audio history.

**Rule**: On periodic reset, truncate `accumulatedMel` to at most one incomplete encoder window. Call `eval()` on the truncated slice to break MLX's lazy reference to the parent array.

### Lesson 2: Always set `Memory.cacheLimit` for long-running sessions

MLX caches freed Metal buffers for reuse. The default limit is ~95% of system RAM. Each prefill pass allocates ~1.2 GB of transient buffers that get cached instead of released.

**Rule**: Set `Memory.cacheLimit` at session start. Use the same value as the non-streaming path (currently 64 MB). Without this, RSS grows by ~1 GB above what `Memory.activeMemory` reports.

### Lesson 3: Call `Memory.clearCache()` at every deallocation boundary

`Memory.clearCache()` was only called after token decoding. Missing it after prefill and during reset caused ~500 MB of leaked cache per reset cycle.

**Rule**: Call `Memory.clearCache()` after prefill (`prefillWithEmbeddingDiff`), after decode (`decodeTokens`), and at the end of `reset()`.

### Lesson 4: MLX array slicing retains the parent

`accumulatedMel![tailStart..<end]` creates a lazy view that holds a reference to the entire original array. Without `eval()`, "truncating" to 800 frames still keeps 98,000 frames in memory.

**Rule**: After slicing an MLXArray to discard old data, always `eval()` the result to force materialization and release the parent.

### Lesson 5: Match mel dtype to encoder weight dtype

The audio encoder weights are bfloat16 but mel spectrogram is computed as float32. When float32 input meets bfloat16 weights, MLX promotes all intermediates to float32 — doubling transient memory from ~95 MB to ~750 MB per encoder forward pass.

**Rule**: Cast mel to bfloat16 at the entry of `encodeSingleWindow`. Cast the sinusoidal positional embedding to match (`posEmb.asType(x.dtype)`) — it's hardcoded to float32 in its initializer. Verify with `x.dtype` logging after conv and after transformer layers.

Note: `.asType(.float16)` does NOT help when weights are `.bfloat16` — MLX promotes float16 × bfloat16 back to float32.

### Lesson 6: Intermediate eval() bounds concurrent tensor memory

MLX lazy evaluation builds the full compute graph before executing. For 24 transformer layers evaluated at once, all layers' intermediate tensors can coexist in memory. Calling `eval()` every 8 layers forces materialization and allows earlier layers' intermediates to be freed.

**Rule**: In transformer loops with many layers, insert `eval(hiddenStates)` periodically (every 8 layers). This reduces peak memory with minimal throughput impact (~3%).

### Lesson 7: Encoder window cache must truly slide

When `EncoderWindowCache` is full, the guard `encoderCache.count < maxEncoderWindows` in `encodeCompleteWindows()` prevented encoding new windows. But `addWindow()` already has eviction logic. The guard caused the tail mel (unencoded portion) to grow unboundedly, with `encodeSingleWindow(tailMel)` processing an ever-larger input.

**Rule**: Remove the cache-full guard — let `addWindow()`'s built-in eviction handle the sliding window. Tail mel should never exceed one encoder window size (800 frames).

### Lesson 8: Activity Monitor double-counts unified memory

On Apple Silicon, Metal buffers are `StorageModeShared` — mmap'd into process address space. Activity Monitor includes them in "Memory" alongside the GPU allocation. `Memory.activeMemory` is the true GPU figure. RSS will always be higher.

**Rule**: Use `Memory.activeMemory` / `Memory.peakMemory` for profiling, not Activity Monitor. See `docs/memory.md` for profiling instructions.

### Reference Implementation

antirez's C implementation ([antirez/qwen-asr](https://github.com/antirez/qwen-asr)) achieves flat O(1) memory by: never persisting mel (computed and freed per-chunk), hard-resetting the KV cache cursor each chunk, and compacting the raw audio buffer on reset. When porting streaming inference, follow this memory model.

## Release Flow (2026-04)

Releases are driven by `.github/workflows/release.yml`, triggered by pushing a tag matching `X.Y.Z`. There is no local release script — CI handles build, DMG creation, and GitHub Release.

### Steps

1. Create the feature/fix commit(s) and push to `master`.
2. Create a **separate** version bump commit:
   - Update `MARKETING_VERSION` to the new version in `project.pbxproj`.
   - Increment `CURRENT_PROJECT_VERSION` by 1 in `project.pbxproj`.
   - Commit message: `chore: bump version to X.Y.Z`.
3. Push the version bump commit.
4. Create and push the tag: `git tag -a X.Y.Z -m "Release X.Y.Z" && git push origin X.Y.Z`.
5. Wait for the Release workflow to complete on GitHub Actions.

### Rules

- **Never amend a pushed commit.** Every change is a new, standalone commit. Do not rewrite shared history.
- **Never force-push master.** If you made a mistake, fix it in a new commit.
- **Never push to remote without explicit user approval.** Always ask before `git push`.
- **Push the tag exactly once.** Do not delete and re-push tags to "retry" — cancel the workflow and re-run it from the GitHub Actions UI instead.
- **One commit per logical change.** A bug fix is one commit. A version bump is another. Deleting a file is another. Do not combine unrelated changes.

### Incident: CJK Repetition Fix Release (2026-04)

Version bump was amend-ed into the fix commit and force-pushed to master, then the tag was deleted and re-pushed 3 times, triggering 3 cancelled release workflows. Root cause: not knowing the release steps and panicking.

**Rule**: Read this section before every release. Follow the steps exactly. When in doubt, stop and ask.
