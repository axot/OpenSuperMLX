# Apple ASR Ideas to Research

Ideas from Apple's on-device speech stack that may improve OpenSuperMLX. Nothing here is
scheduled work; each item names the evidence behind it and how to measure it.

## What Apple ships

The macOS 26 `SpeechAnalyzer` / `SpeechTranscriber` APIs run inside the system process
`SpeechRecognitionCore.speechrecognitiond`, outside the calling app's memory. The Chinese
asset bundle (about 1.1 GB) contains the parts below. Their roles are inferred from asset
names and sizes, not from documentation.

| Asset | Size | Likely role |
|---|---|---|
| Acoustic encoder (Neural Engine) | ~88 MiB | Speech to acoustic tokens |
| Small language model | ~111 MiB | Rescoring / fusion |
| `ASRTaggerElectra` | ~67 MiB | Span tagging for ITN or punctuation |
| WFST lexicon graph | ~185 MiB | Constrained decoding |
| ITN / punctuation | ~42 MiB | Written-form rendering |
| Context encoder | ~7 MiB | User vocabulary biasing |
| G2P, confidence model, rescoring | small | Custom words, scores |

The English model has a 28-layer encoder that keeps attention state in about four layers,
a 151 MiB Neural Engine encoder, and a 36 MiB BNNS (CPU) decoder.

## TODO

- [ ] **Tag-then-verbalize ITN.** Apple pairs a neural span tagger with its ITN assets,
  which suggests normalization runs only on tagged spans. Our WeTextProcessing rules run on
  the whole string and can drop conversational particles (你好啊 → 你好). Research a span gate
  before FST ITN, and route by script (Han → Chinese ITN, Latin → English ITN); the
  `MultilingualTextSpanRouter` prototype is on `feat/sensevoice-apple-pipeline-mvp`.
  Measure: false normalizations on a sample of stored transcripts.
- [ ] **Personal vocabulary.** Apple injects user terms through its context encoder and G2P.
  In our zh/en recordings, English technical terms (Safari, SQLite, Codex, worktree) caused
  about half of the mixed-speech errors in the SenseVoice comparison. Research building a
  term list from transcript history and passing it as Qwen3-ASR context text.
  Measure: term recall on mixed zh/en recordings.
- [ ] **Token-level confidence.** Apple exposes confidence per result. In the SenseVoice
  experiment, per-token margins separated errors well (AUC 0.80) while per-window flags did
  not. Research exposing Qwen decoder token log-probabilities, then highlighting or
  LLM-correcting only low-confidence spans.
- [ ] **Separate punctuation pass.** Apple ships a dedicated punctuation asset; Qwen emits
  punctuation itself and it can change between streaming chunks. Research whether a small
  punctuation model stabilizes streaming output.
- [ ] **Incremental streaming encoder.** Apple's encoder keeps attention state; our streaming
  path re-encodes the partial tail window every 2 s. Research caching the tail encoding.
  Measure: encoder time per audio second.
- [ ] **Idle model unload.** `speechrecognitiond` loads one shared model and can unload it.
  Research unloading our model after an idle period and preloading on the recording
  shortcut. Measure: memory returned and reload latency.
- [ ] **Pause-based finalization.** Apple promotes volatile results to final at pauses.
  Research finalizing text at pauses detected from model output, without gating the
  microphone. Measure: latency until final text.
- [ ] **Filler words.** Decide a policy for 呃 / 嗯 (drop for dictation, keep for meeting
  transcripts?).
- [ ] **LM rescoring or WFST (low priority).** Qwen's decoder is already a language model,
  and a WFST needs a closed lexicon that conflicts with open-vocabulary mixed-language
  speech. Revisit only if a CTC model is used again.
