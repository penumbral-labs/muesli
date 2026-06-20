# Plan: Add Nemotron 3.5 Multilingual Streaming ASR as a model option

**Date:** 2026-06-20
**Branch:** `claude/nemotron-asr-streaming-msek2t`
**Status:** Spec only — no code written. Author this in a Mac-side session with HuggingFace network access (this remote env blocks `huggingface.co` egress and cannot build/run CoreML).

---

## 1. Goal

Add NVIDIA's [`nemotron-3.5-asr-streaming-0.6b`](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b) as a **second, multilingual** Nemotron option alongside the existing English-only `nemotron-speech-streaming-en-0.6b-coreml`.

Ship via the FluidInference CoreML/ANE conversion:
[`FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML`](https://huggingface.co/FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML).

**Wins over the current EN backend:** 40 language-locales (en/es/fr/it/pt/de + zh/ja + 100+ via language prompt), newer base checkpoint (2026-05-29), and **native punctuation in the vocab** (removes the current backend's "no punctuation" limitation).

---

## 2. Why this is NOT a one-line URL swap

The 3.5 model has a **different CoreML interface** than the constants hardcoded in `NemotronStreamingBackend.swift`. Confirmed differences from public docs (must be re-verified against the actual `config.json`/`metadata.json` — see §5):

| Aspect | Current EN (`NemotronStreamingTranscriber`) | Nemotron 3.5 multilingual |
|---|---|---|
| Vocab size / blank id | `1024` / `1024` | `13087` (full) or `2828` (Latin-pruned) / `= vocabSize` |
| Encoder caches | `cache_channel [1,24,70,1024]`, `cache_time [1,24,1024,8]`, `cache_len [1]` | `cache_last_channel [24,1,56,1024]`, `cache_last_time [24,1,1024,8]`, `pre_cache [1,128,9]`, `cache_last_channel_len [1]` |
| Encoder language input | none | **6th input** for language selection — name/shape unconfirmed: either `prompt_index` (int64 `[batch]`, `101` = auto-detect) **or** one-hot `language_mask [1,128]`. **VERIFY.** |
| Tokenizer files | `tokenizer.json` (`{id_string: piece}`) | SentencePiece `tokenizer.model` + `vocab.json` + `languages.json` + `config.json` |
| Decoder | 2-layer LSTM, `pred_hidden=640` (same) | 2-layer LSTM, `pred_hidden=640` (same — likely reusable) |
| Encoder dim | `1024` | `1024` (d_model, 24 Conformer layers — same) |
| Chunk variants | `560ms` only | `80 / 320 / 560 / 1120 ms` (320ms is FluidInference's published default bundle) |
| Subsampling | — | 8× (one encoder frame / 80ms) |

Because the cache shapes, I/O feature names, vocab, and the new language input all differ, this needs a **new backend type** (or a parameterized one), not a repointed URL on the existing `nemotron` backend.

---

## 3. Decision: new backend identifier

Introduce a new backend string `"nemotron35"` (do **not** overload the existing `"nemotron"`). This keeps the working EN backend untouched and avoids branching its hot path on model shape.

Recommended default chunk variant: **320ms** (FluidInference's published bundle; good latency/accuracy balance). Optionally expose 560/1120ms later.

Language default: **auto-detect** (the `101`/auto sentinel). A language picker in Settings is a follow-up, not required for v1.

---

## 4. Files to touch (integration surface)

All paths under `native/MuesliNative/Sources/MuesliNativeApp/` unless noted. Line numbers are approximate as of this branch.

### 4.1 `Models.swift`
- Add a `BackendOption`:
  ```swift
  static let nemotron35Multilingual = BackendOption(
      backend: "nemotron35",
      model: "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML",
      label: "Nemotron 3.5 Multilingual (Experimental)",
      sizeLabel: "~600 MB",   // confirm actual bundle size for the 320ms variant
      description: "Experimental. NVIDIA Nemotron 3.5 streaming RNNT, 40 language-locales. Native punctuation. Handsfree mode only. Append-only — no corrections.",
      recommended: false
  )
  ```
- Add it to `static let experimental` (line ~114) and therefore `all`.
- Extend `isAvailableLocally(...)` (the `switch` near line ~173) with a `case "nemotron35":` checking the on-disk cache marker file (mirror the EN check — e.g. `.cache/muesli/models/nemotron35-320ms/encoder/encoder*.mlmodelc/coremldata.bin`). Confirm the encoder filename from the repo tree (may be `encoder.mlmodelc` or quantized `encoder_int8.mlmodelc`).

### 4.2 New backend file `Nemotron35StreamingBackend.swift`
Clone `NemotronStreamingBackend.swift` as a starting point, then change:
- **Cache shapes & names** in `makeStreamState()` and the encoder `MLDictionaryFeatureProvider` (see §2 table). Add `pre_cache` and rename `cache_channel→cache_last_channel`, `cache_time→cache_last_time`, `cache_len→cache_last_channel_len`. Match the actual output feature names for the `*_out` writes-back.
- **Add language input** to the encoder feature dict (the 6th input). Build it once per stream from the selected language (auto = sentinel). VERIFY name/dtype/shape.
- **Vocab/blank**: read from `config.json` if present; otherwise set `vocabSize`/`blankTokenId` from the bundle (13087 multilingual or 2828 Latin-pruned). Do **not** hardcode 1024.
- **Tokenizer/decode**: the EN path maps `tokenizer.json {id:piece}` and replaces `▁`. The 3.5 bundle ships `vocab.json` (likely `{piece: id}` or an array) + SentencePiece `tokenizer.model`. Implement decode from `vocab.json` (id→piece) with `▁`→space. Native punctuation means **drop** any punctuation-stripping. Strip the per-language tag suffix the model can emit at utterance end (see model card — VERIFY token format).
- **Chunk geometry**: set `chunkSamples`, mel-frame counts, `encoderOutputFrames` from the 320ms variant's `config.json`. (560ms EN values do **not** transfer.)
- **Download**: point `cacheDir` to `.cache/muesli/models/nemotron35-320ms` and the HF tree/resolve URLs to the new repo + the 320ms subfolder. Reuse the existing `downloadDirectory`/`downloadWithRetry` helpers verbatim.

### 4.3 `TranscriptionRuntime.swift`
- Add a lazy `_nemotron35Transcriber: Any?` + accessor mirroring `nemotronTranscriber` (lines ~19–39).
- `prepareBackend`/load switch (line ~191): add `case "nemotron35":` with the same `#available(macOS 15, *)` guard and a silent-chunk warmup (use the new `chunkSamples`, not 8960).
- Transcribe switch (line ~446): add `case "nemotron35": return try await transcribeWithNemotron35(url:)` and implement the wrapper (clone `transcribeWithNemotron`, lines ~549).
- `shutdown` (line ~345): add `await nemotron35Transcriber.shutdown()`.

### 4.4 `StreamingDictationController.swift`
- The `NemotronStreamingTranscribing` protocol (line ~15) + adapter is tied to `NemotronStreamingTranscriber.StreamState`. Two options:
  1. **Generic over StreamState** (cleaner): make the protocol/`StreamingDictationController` generic so both transcribers conform; or
  2. **Parallel adapter**: add a `Nemotron35StreamingTranscriberAdapter` + a second convenience init.
  Recommend (1) if StreamState differences are small; otherwise (2) to avoid touching the working EN path.
- Wherever `MuesliController`/dictation chooses the streaming controller for `backend == "nemotron"`, branch to also accept `"nemotron35"` (grep `getNemotronTranscriber()` / streaming-dictation construction in `MuesliController.swift`).

### 4.5 `ModelsView.swift`
- The new option appears automatically via `experimental`/`all`. Verify the experimental section renders it and the download/progress UI keys off `backend`/`model` correctly. Add an "Experimental / handsfree only" badge consistent with the EN entry.

### 4.6 Tests — `Tests/MuesliTests/`
- `ModelsTests.swift`: assert the new option exists, has `backend == "nemotron35"`, correct model id, and is in `experimental`/`all`.
- `BackendTests.swift` / `TranscriptionRuntimeTests.swift`: extend any `switch backend` exhaustiveness/coverage tests.
- `NemotronStreamingTests.swift`: add a sibling suite for the new backend's pure helpers (token decode, language-input construction, state init shapes). Guard CoreML-dependent tests behind model availability as the existing suite does.
- Target: keep the suite green (currently 396 tests / 65 suites — `swift test --package-path native/MuesliNative`).

---

## 5. MUST-VERIFY before/while coding (needs HF access + a Mac)

These are the items I could not confirm from this environment. Pull them from the FluidInference repo's `config.json` / `metadata.json` / model `.mlmodelc` `metadata`:

1. **Repo tree & variant folder names** — confirm the 320ms subfolder path and exact `.mlmodelc` filenames (quantized vs f32 encoder). Mirror the EN `downloadDirectory` API/resolve URL pattern.
2. **Encoder I/O feature names & shapes** — `mel`/`audio` input name, cache input/output names, and especially the **language input** (`prompt_index` int64 `[batch]` vs one-hot `language_mask [1,128]`) and its auto-detect sentinel value.
3. **Vocab size + blank id** + whether the shipped bundle is the 13087 (full) or 2828 (Latin-pruned) vocab — and which FluidInference publishes by default.
4. **Tokenizer format** — structure of `vocab.json` (id→piece vs piece→id vs array), space marker (`▁`), and the per-language suffix-tag token format to strip.
5. **Chunk geometry** for 320ms — `chunkSamples`, mel window/hop frame counts, encoder output frames per chunk.
6. **Bundle size** for the `sizeLabel` string.
7. **License** — confirm NVIDIA's model license permits redistribution/use in a shipped app (the EN one is already shipped, but 3.5 license terms should be re-checked).

---

## 6. Caveats to surface in UI / docs (carry forward to CLAUDE.md "Known Limitations")

- Same RNNT limitations as the EN backend: **append-only, no corrections, handsfree-oriented, weak on very short dictations.** Keep it handsfree-mode-only.
- First run pays CoreML ANE compilation warmup cost (mitigated by silent-chunk warmup on load).
- Multilingual accuracy varies by language; some locales are "adaptation-ready" only (need fine-tuning). Set expectations in the model description.
- Larger vocab (13087) → slightly heavier joint/argmax per frame than the EN 1024 path; profile on lowest-supported hardware.

---

## 7. Suggested sequencing

1. (Mac, HF access) Inspect repo → fill in all §5 unknowns.
2. Add `Models.swift` entry + `isAvailableLocally` + tests for those (cheap, no model needed).
3. Implement `Nemotron35StreamingBackend.swift` against verified shapes; unit-test pure helpers.
4. Wire `TranscriptionRuntime` + `StreamingDictationController`/`MuesliController` routing.
5. `./scripts/dev-test.sh` → download model → real handsfree dictation in 2–3 languages.
6. Update `CLAUDE.md` (model count 7→8, Known Limitations) + this Context note.
7. PR.

---

## 8. Sources
- https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b
- https://huggingface.co/FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML
- https://github.com/soniqo/speech-swift/blob/main/docs/models/nemotron-asr-streaming.md
- https://github.com/k2-fsa/sherpa-onnx/issues/3664 (prompt_index language conditioning)
- https://www.marktechpost.com/2026/06/06/nvidia-releases-nemotron-3-5-asr-a-600m-parameter-cache-aware-streaming-model-transcribing-40-language-locales-in-real-time/
