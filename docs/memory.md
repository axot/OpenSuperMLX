# Memory Profiling

## Quick Check

```bash
# Process RSS + compressed (what Activity Monitor shows)
top -l 1 -pid $(pgrep OpenSuperMLX) -stats pid,command,mem,cmprs

# MLX GPU memory (what the model actually uses)
# Add to any Swift code:
Memory.activeMemory   // current GPU allocations
Memory.peakMemory     // session high-water mark
Memory.cacheMemory    // MLX's internal buffer cache
```

Activity Monitor's "Memory" column on Apple Silicon **double-counts** GPU memory — Metal buffers are mmap'd into the process address space, so unified memory appears in both the GPU allocation and the process RSS. Use MLX's `Memory.activeMemory` for the true GPU figure.

## Memory Budget (Qwen3-ASR-1.7B-5bit)

| Component | Size | Where |
|---|---|---|
| Model weights | ~1,820 MB (5-bit decoder ~1,190 MB + BF16 audio encoder ~635 MB) | GPU (MLX), fixed after load |
| Neural Engine audio encoder (when enabled) | ~300 MB INT8, replaces the ~635 MB MLX encoder | Core ML, mapped outside the app's footprint |
| Encoder cache (4 windows) | ~60 MB | GPU, bounded by `maxEncoderWindows` |
| KV cache (decoder) | ~100-200 MB | GPU, bounded by sliding window + prefix cap |
| Decoder prefill transient | ~1.2 MB per row, ≤ ~350 MB per 256-row pass | GPU, freed after each prefill pass |
| Encoder transient (per window) | ~95 MB | GPU, freed after each encoder forward pass |
| Audio samples (`[Float]`) | ~5 MB/min | CPU, proportional to input duration |
| Mel spectrogram tail | <0.4 MB | GPU, truncated each reset cycle |
| Metal driver overhead | ~300 MB | Kernel, unavoidable framework cost |
| Swift runtime + dylibs | ~200 MB | CPU |

Measured peak process footprint (`stream-simulate`, seven 11–43 s clips, Debug build, M1 Max): **~2,230 MB median / 2,720 MB max** with the GPU encoder and **~1,620 MB median / 2,110 MB max** with the Neural Engine encoder. The previous Qwen3-ASR-1.7B-8bit build measured ~2,840 MB median / 3,240 MB max.

Capping prefill passes at 256 rows and computing logits only for the rows that need them lowered the peak on a 43 s clip (Release build, Neural Engine encoder) from ~2,120 MB to ~1,720 MB, and on a 5-minute file transcription from ~3,560 MB to ~2,370 MB.

### Encoder dtype

The audio encoder weights are bfloat16. Mel spectrogram input is cast to bfloat16 at the entry of `encodeSingleWindow` to match — otherwise MLX promotes all intermediates to float32, doubling transient memory. The sinusoidal positional embedding is also cast to match (`posEmb.asType(x.dtype)`).

The encoder transformer uses intermediate `eval()` every 8 layers (instead of all 24 at once) to limit concurrent intermediate tensor memory.

## CLI Profiling

Use CLI mode to profile without GUI overhead:

```bash
./build/Build/Products/Debug/OpenSuperMLX.app/Contents/MacOS/OpenSuperMLX \
  transcribe ~/path/to/audio.wav --language auto
```

To add memory checkpoints to the active CLI path, insert them in `OpenSuperMLX/CLI/Commands/TranscribeCommand.swift`:

```swift
let act = String(format: "%.1f", Double(Memory.activeMemory) / 1e6)
let peak = String(format: "%.1f", Double(Memory.peakMemory) / 1e6)
fputs("[mem] act=\(act)MB peak=\(peak)MB\n", stderr)
```

For per-process RSS from outside:

```bash
# One-shot
top -l 1 -pid $(pgrep OpenSuperMLX) -stats pid,command,mem,vsize,cmprs

# RSS in MB via mach API (what we use in code)
var info = mach_task_basic_info()
var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
withUnsafeMutablePointer(to: &info) {
    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
    }
}
let rssMB = Double(info.resident_size) / 1e6
```

## Streaming Memory Invariants

The streaming pipeline (`ContinuousChunkProcessor`) must maintain O(1) memory regardless of audio duration:

1. **Mel buffer**: truncated to tail (<1 encoder window) on every periodic reset
2. **Encoder cache**: sliding window, max `maxEncoderWindows` (default 4)
3. **KV cache**: rebuilt from bounded context after each reset — prefix capped at `maxPrefixTokens` (150)
4. **MLX cache**: cleared via `Memory.clearCache()` in `reset()` and after each decode pass
5. **Prefill**: `Qwen3ASRModel.prefill` runs at most `prefillRowsPerPass` (256) rows per pass and projects only the last rows onto the vocabulary, so rebuilding the prompt after a window eviction stays bounded. Smaller passes cost GPU efficiency: matmuls run in 32-row tiles, and passes under 8 tiles are slower per tile.

Periodic reset fires every `resetIntervalChunks` chunks (default 45 × 2s = 90s). Between resets, mel grows to ~9,000 frames (~4.6 MB) which is acceptable.

### Red Flags

If you see any of these in profiling, there is a memory regression:

- `Memory.activeMemory` increasing across reset cycles
- `Memory.peakMemory` increasing across reset cycles
- `Memory.cacheMemory` growing beyond ~200 MB between resets
- `accumulatedMelFrameCount` exceeding `2 × resetIntervalChunks × chunkSizeMelFrames` (~18,000 frames)

## Recording Save Recovery Buffer

Streaming capture also retains mono 16 kHz Int16 PCM until the recording is saved or the user confirms Cancel. This buffer is deliberately duration-proportional and separate from the model's bounded streaming state:

| Duration | Recovery PCM |
|---|---:|
| 1 minute | 1.92 MB |
| 30 minutes | 57.6 MB |
| 1 hour | 115.2 MB |

The detached feed task is the sole owner while recording. Stop and Cancel await that task before transferring or releasing the buffer. AAC failure does not stop PCM collection. Successful persistence or confirmed Cancel releases the full buffer; Retry keeps it unchanged and re-encodes all samples.

### Reference: antirez/qwen-asr

The C reference implementation ([antirez/qwen-asr](https://github.com/antirez/qwen-asr)) achieves flat memory by:
- Never persisting mel — computed and `free()`'d per-chunk
- Hard-resetting `kv_cache_len` cursor each chunk (capacity stays, working length bounded)
- `stream_clear_enc_cache()` + audio buffer compaction on reset
- Max KV working size bounded by `4 encoder windows + 150 prefix tokens + fixed overhead`
