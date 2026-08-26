# Audio Diagnostics

Quick reference for diagnosing audio quality issues in speaker capture (mic + system audio mixing).

## Pipeline Overview

```
Mic → AVAudioEngine tap (48kHz) → ringBuffer → drain every ~100ms
                                                         ↓
Sys → ScreenCaptureKit (matched rate) → accumulatedSamples → drain
                                                         ↓
                                            AudioMixer.mix()
                                         AGC → ceiling → resample → carry-over → tanh
                                                         ↓
                          ┌──────────────┴──────────────┐
                          ↓                             ↓
             AACRecordingWriter             PCMRetryBuffer (Int16)
             16kHz mono, 48kbps              retained until save/cancel
```

**Note on AEC:** VPIO (`setVoiceProcessingEnabled`) was removed. AEC is now handled at the routing layer via `OutputDeviceClassifier`: if the active output device is classified as a speaker AND the user enabled system-audio capture, the routing forces mic-only to avoid the speaker→mic echo path. Headphone outputs allow free mic+sys mixing.

## Enable Pipeline Trace

1. Turn on **Debug Mode** in Settings
2. Record audio
3. Trace file: `$TMPDIR/temp_recordings/{timestamp}_pipeline.log`

### Reading the Trace

```
[UI]     ContentView.startRecording()           ← entry point
[STREAM] streaming started speakerEnabled=true  ← speaker capture on?
[SCK]    capture started                        ← ScreenCaptureKit active
[FEED]   mic=4800 sys=4800 out=1600             ← per-cycle: raw counts + output
[ARCHIVE] wrote 1600 samples                    ← what actually hit disk
```

**Healthy pattern:** `mic=4800 sys=4800 out=1600` (steady, matched counts)
**Jitter:** `sys=5760` or `sys=6720` (SCK delivered extra callbacks — carry-over handles this)
**Spike:** `mic=43200 sys=44160` (feed loop was blocked — check if transcription inference stalled)

## Analyzing a Recording

New recordings are 16kHz mono AAC-LC M4A at 48kbps. Verify their container metadata first:

```bash
afinfo RECORDING.m4a
```

For sample-level analysis, decode a copy to 16kHz Float32 WAV:

```bash
afconvert RECORDING.m4a /tmp/recording-analysis.wav -f WAVE -d LEF32@16000
```

Legacy recordings are 16kHz Float32 WAV. Analyze either a legacy file or the decoded copy with Python:

```bash
python3 -c "
import struct, numpy as np
with open('RECORDING.wav', 'rb') as f:
    f.read(12)
    while True:
        cid = f.read(4)
        if len(cid)<4: break
        sz = struct.unpack('<I', f.read(4))[0]
        if cid == b'fmt ':
            d = f.read(sz)
            sr = struct.unpack('<I', d[4:8])[0]
        elif cid == b'data':
            s = np.frombuffer(f.read(sz), dtype=np.float32); break
        else: f.seek(sz, 1)
print(f'{sr}Hz {len(s)} samples ({len(s)/sr:.1f}s)')
print(f'Peak: {np.abs(s).max():.4f}')
print(f'Clipped (±1.0): {np.sum(np.abs(s)>=1.0)}')
print(f'Pops (Δ>0.3): {np.sum(np.abs(np.diff(s))>0.3)}')
# Silence gaps >10ms
g = np.abs(s)<0.002; d = np.diff(g.astype(int))
for a,b in zip(np.where(d==1)[0]+1, np.where(d==-1)[0]+1):
    dur = (b-a)/sr*1000
    if dur>10 and a>sr: print(f'  Gap @{a/sr:.2f}s {dur:.0f}ms')
"
```

## Save Recovery

If direct AAC writing, validation, final installation, or database insertion fails after streaming stops, the transcript and complete Int16 audio remain in memory. The recovery panel offers:

- **Retry** — streaming recordings re-encode the entire PCM buffer; non-streaming recordings revalidate their completed temporary M4A. Both use atomic installation and idempotent database persistence.
- **Copy Transcript** — copies the final corrected text without releasing recovery state.
- **Cancel Save** — requires confirmation, removes coordinator-owned temporary/orphan files, and releases the buffer.

A failed Retry leaves the same panel and buffer active. New recordings and normal app termination remain blocked until Retry succeeds or Cancel is confirmed. Force quit and process crashes cannot preserve an in-memory recovery.

For Debug builds, set `"forceRecordingSaveFailure": true` in `dev_config.json` to exercise this panel without filling the disk.

## Known Issue Patterns

### Hard Clipping (爆音)
- **Symptom:** samples at exactly ±1.0, distorted loud passages
- **Check:** `np.sum(np.abs(s) >= 1.0)` — should be 0
- **Cause:** RMSNormalizer gain too high, or missing soft limiter
- **Fixed by:** maxGainDB cap, peak ceiling, tanh soft saturation

### Silence Gate Pops (爆裂声)
- **Symptom:** thousands of pops (Δ>0.3), chunks replaced by exact zeros
- **Check:** `np.sum(s == 0.0)` in non-silent regions
- **Cause:** `mix()` silence gate replacing low-RMS chunks with zeros
- **Fixed by:** removing the silence gate (ASR models have built-in VAD)

### Sample Rate Mismatch
- **Symptom:** sys audio pitch-shifted ~9%, periodic zero-padding gaps
- **Check:** trace shows `out` much larger than expected (e.g., out=2089 when expecting ~1600)
- **Cause:** mic at 48kHz, sys at 44100Hz, mixed as same rate
- **Fixed by:** SCK `sampleRate` matches mic native rate; independent resampling

### Callback Jitter Gaps
- **Symptom:** variable chunk sizes, intermittent near-zero regions in continuous audio
- **Check:** trace shows `sys` count varying 4800-6720 between cycles
- **Cause:** SCK delivers audio in bursts; zero-padding shorter source
- **Fixed by:** carry-over buffer (excess samples deferred to next cycle)

### Feed Loop Blocking
- **Symptom:** trace shows 400ms+ gaps between FEED lines; huge sample counts (30000+)
- **Check:** trace timestamps — gap between consecutive `[FEED]` lines > 200ms
- **Cause:** synchronous `await MainActor.run` or slow `session.feedAudio()` blocking the loop
- **Fixed by:** fire-and-forget `Task { @MainActor in }` for UI updates
