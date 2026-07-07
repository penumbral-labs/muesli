# Streaming Live Transcript for Meetings (issue #99)

## Problem

The live transcript tab (PR #182) simulates streaming: audio buffers until a VAD
pause boundary (3–5s), the chunk is batch-transcribed (1–3s more), and a
finished line is appended. Words appear 5–8s after they are spoken and never
mid-sentence. Maintainer steer on #99: build a Granola-type streaming UI backed
by a streaming-native model, not more VAD-chunk simulation.

## Approach: hybrid display layer

VAD chunks stay the durable commit mechanism — checkpoints, diarization, crash
recovery, resume, and the final transcript are untouched. Streaming partials are
a display-only layer for the in-flight segment: a dimmed, italic "tail" bubble
per source that updates as speech happens and settles into the committed
caption when the chunk transcribes.

The partials engine is the in-repo Nemotron 3.5 streaming stack
(`Nemotron35StreamingTranscriber` + per-session `RNNTStreamState`), running two
independent sessions (mic "You", system "Others") that serialize through the
one model actor. It runs regardless of the selected committed-transcript
backend; partial text is provisional by definition and replaced at commit.

### Gating

- macOS 15+ (availability of the streaming stack)
- Nemotron 3.5 model already downloaded and loaded — never triggers a download
- `enable_live_streaming_partials` config (default true) as a kill switch

Without the model, the live view behaves exactly as before.

### Non-goals (v1)

- Word-by-word granularity — cadence is Nemotron's native 2.24s chunk.
  Fast-follow path: Parakeet sliding-window partials (FluidAudio ships
  `TdtDecoderState`, not yet wired in Muesli's file-based wrapper).
- Replacing the chunk pipeline; live notes-on-demand (separate PR); in-meeting chat.

## Architecture

- **`MeetingStreamingPartialSession`** (new): per-source buffer + serial drain.
  `enqueue([Float])` is called on `chunkRotationQueue` (cheap append under a
  lock); a single-flight drain slices 35840-sample chunks and calls
  `transcribeChunk(samples:state:&)` on the shared transcriber, firing
  `onPartialUpdate` with the current tail text. `markSegmentBoundary()`
  (from chunk rotation) snapshots the accumulated text length;
  `commitSegment()` (when the committed line lands) drops that prefix so the
  tail keeps only text newer than the committed chunk.
- **`MeetingSession`**: taps AEC'd mic floats and raw system floats (the same
  streams the VADs consume), feeds the two sessions, marks boundaries in the
  rotation handlers, commits next to `onChunkTranscribed`, tears down with the
  VAD controllers.
- **`TranscriptionCoordinator.getLoadedNemotron35TranscriberIfAvailable()`**:
  returns the transcriber only if already loaded.
- **AppState**: `liveMeetingPartialYou` / `liveMeetingPartialOthers`,
  owner-gated by the existing `liveMeetingTranscriptOwnerID`, cleared wherever
  the live transcript is cleared.
- **`LiveTranscriptView`**: renders the partial tails as dimmed italic bubbles
  after the committed caption groups, outside the incremental-parse
  (`parsedLength`) invariant — partials never enter the transcript string.

## Edge cases

- Both sessions busy: calls interleave through one actor; worst-case partial
  lag ~4.5s. Accepted for v1; measured in live verification.
- Rotation→commit gap: the frozen prefix stays visible until commit (no
  flicker-to-empty).
- Pause: tails clear, feeding stops; resume re-feeds (a silence gap in RNNT
  state is harmless for display-only text).
- Transcriber failure mid-meeting: the session logs once and goes dormant;
  committed path unaffected.

## Risks

- ANE contention between two RNN-T sessions and the per-chunk batch backend —
  measured with `scripts/monitor-memory.sh` during a long meeting; fallback is
  mic-only partials.
- Partial/committed text mismatch when the committed backend differs from
  Nemotron — provisional text settles; inherent to the hybrid design.
