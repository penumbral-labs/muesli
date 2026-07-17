# Issue #322 meeting microphone handoff

## Published work

- Issue: [#322 — Google Meet Microphone Inconsistency](https://github.com/Muesli-HQ/muesli/issues/322)
- Draft PR: [#327 — Prevent meeting capture from disrupting the default microphone](https://github.com/Muesli-HQ/muesli/pull/327)
- Focused branch: `codex/fix-322-meeting-microphone`
- Base: `origin/main`

The PR contains four focused commits:

1. Avoid blocking meeting startup on CoreAudio route refresh.
2. Use the system-default streaming recorder when the desired meeting mic is already the system default.
3. Suppress repeated prompts for a meeting session that has already started recording.
4. Refresh cached routes when the CoreAudio device inventory changes, including selected-mic unplug/reconnect.

## Diagnosis

Muesli represented the built-in/default microphone as an explicit meeting-device preference. This selected the app-scoped `AudioQueue` recorder even when the same physical microphone was already the macOS default used by the meeting client.

The deterministic diagnostic harness reproduced the issue shape:

- system-audio process tap started successfully
- microphone `AudioQueueStart` blocked for about 15 seconds
- start returned `kAudioQueueErr_CannotStart` (`-66681`)
- failed-queue cleanup blocked for about another 30 seconds

This supports the unnecessary explicit microphone graph and its CoreAudio lifecycle as the cause of the startup-order race. The fix is shared by all supported meeting applications and browsers; it is not Google Meet-specific.

## Scope decision

The broader investigation branch is preserved locally as `codex/diagnose-issue-322-meeting-mic` at `223fb511`. It contains the opt-in stress harness and detailed meeting lifecycle diagnostics used to reproduce the failure.

Those diagnostics were intentionally excluded from PR #327 because some instrumentation still performed release-time callback bookkeeping and an additional `AudioQueueGetProperty` in the timing-sensitive startup path. The focused PR also excludes the unrelated speculative-dictation experiment and its revert history.

## Validation

- 85 focused tests pass across route selection, recorder behavior, meeting candidate resolution, media-session tracking, prompt suppression, and selected-mic hot-plug behavior.
- Muesli-first then Google Meet: both clients shared the built-in mic and participants heard the user.
- Google Meet-first then Muesli auto-detection: Muesli used `systemDefaultStreaming`; microphone and system-audio capture remained healthy.
- Discard while the external meeting remained active: teardown completed normally and the same session did not prompt again after cooldown.
- Chrome, Muesli, and CoreAudio were not restarted between the relevant live lifecycle transitions.

Earlier full-suite runs were noisy under combined system load, with independently passing flakes in streaming VAD, Nemotron timeout, and clipboard tests. PR CI is the source of truth for the complete suite.

## Follow-up

- Let PR #327 CI and review complete before marking it ready.
- If #322-like behavior returns, use the preserved diagnostic branch to collect a trace, but do not merge its release-time instrumentation without removing the callback/startup overhead.
- Repeat both startup orders with a non-default external microphone before release if hardware is available; the explicit route is intentionally retained for that case.
