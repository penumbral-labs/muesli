# PR #320 meeting microphone route recovery

## Pull request

- PR: [#320 — Fix: microphone capture dies silently when the default input device changes mid-recording](https://github.com/Muesli-HQ/muesli/pull/320)
- Branch: `fix/mic-capture-survives-input-device-change`
- Base: `origin/main`
- Original contributor commits by Denis remain intact. Maintainer hardening is layered on top after merging current `main`.

## User-visible behavior

- A meeting recording follows a default-input change, including connecting AirPods mid-meeting, without silently losing the local microphone.
- Meetings have an independent microphone selector under Settings > Meetings.
- Changing the Meetings microphone during an active meeting applies immediately to Muesli's capture and does not change the meeting application's microphone selection.
- Route changes create a controlled chunk boundary while preserving the meeting, transcript, microphone/system timing, AEC, and VAD lifecycle.
- Failed or stale graph callbacks cannot revive an old recording generation or write into a replacement recording.

## Reliability design

- Microphone restarts are coordinated and coalesced across configuration changes and explicit selection changes.
- A replacement graph must deliver its first audio buffer before the handoff is considered successful.
- Generation tokens reject callbacks from stopped, replaced, or failed graphs.
- Recovery retries after route settlement and can fall back to the system-default recorder where appropriate.
- AVFAudio graph operations that may raise Objective-C exceptions are contained by `AudioGraphExceptionBridge`, so a recoverable hardware transition does not terminate Muesli.
- Graph format validation prevents unstable or invalid hardware formats from being installed.
- Teardown and restart work stay off UI-owned lifecycle paths.

## Validation

- Full local suite: 1,531 tests in 145 suites passed.
- Focused route and fallback suite: 34 tests passed.
- Broader route and configuration suite: 100 tests passed.
- App configuration and migration suite: 58 tests passed.
- `git diff --check` passed.
- MuesliDevA built and launched successfully with the final settings copy.

### AirPods reproduction

The original real-world sequence was repeated in one active meeting:

1. Start recording on the built-in microphone.
2. Connect AirPods while recording.
3. Continue speaking and then finish the meeting.

The recorder stopped the built-in route, started the AirPods input, rebuilt the aggregate capture graph, and continued the same meeting. Local-microphone transcript segments were present before and after the transition, remote audio continued, and the app did not crash. The observed graph transition gap was about 1.9 seconds.

macOS also changed its global default input to AirPods during this run. That matches the primary #320 scenario. An isolated Muesli-selector test with the macOS default held fixed remains useful coverage, but it is not required to validate the reported AirPods failure.

## Deliberate boundary

The Meetings live-preview model setting is adjacent but independent. Turning preview off during an active meeting stops low-latency partials; turning it on or changing its model takes effect on the next meeting. That lifecycle behavior is not part of #320.
