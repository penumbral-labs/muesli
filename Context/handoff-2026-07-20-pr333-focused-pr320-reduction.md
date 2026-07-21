# PR #333 focused #320 reduction

## Scope decision

The earlier branch tip combined the original #320 fix with a 39-file meeting lifecycle expansion in `6d515c45`, then added a large follow-up layer in `561afad3`. The broad tip is preserved locally as `archive/pr333-full-lifecycle-20260720` at `5c36d65b`.

The active branch now preserves contributor history but reverses the broad lifecycle expansion. Its net diff against current `origin/main` is intentionally limited to meeting microphone route recovery, the Meetings microphone selector, concise copy and live-preview semantics, and privacy-safe failure telemetry.

## Focused behavior

- Meeting AVAudioEngine capture can rebuild after an input configuration change.
- Objective-C exceptions raised by AVFAudio graph mutations are converted to Swift errors for meeting capture only.
- Dictation uses the same default-off recorder path as `origin/main`; it does not opt into meeting route recovery.
- Meetings store a microphone choice independently from Dictation. Existing users default to Automatic instead of inheriting a Dictation device.
- An active meeting keeps the current recorder alive while a replacement starts. The handoff completes only after the replacement produces its first audio buffer.
- Failed or timed-out replacements are cancelled and the existing recorder continues.
- Generation checks reject stale replacement callbacks during rapid route changes, pause, stop, and discard.
- Meeting microphone capture failures emit allowlisted TelemetryDeck diagnostics without device names, UIDs, transcript text, paths, or raw error descriptions.

## Settings semantics

- `Show transcript on hover` controls whether recent completed transcript segments appear beside the waveform.
- `Live preview model: Off` disables low-latency streaming partials. It does not hide already completed transcript segments.
- Turning preview off during a meeting keeps the existing mainline behavior: active streaming partial sessions stop and partial tails clear.
- Turning preview on or changing its model still takes effect on the next meeting. That separate preview-engine restart lifecycle is outside #320.

## Validation target

Run focused route, config, and diagnostic suites, then the complete Swift package test suite. Real-world validation should start a meeting on the built-in microphone, connect and disconnect AirPods, change only the Meetings selector while macOS remains on its existing input, and verify local speech before and after each transition.
