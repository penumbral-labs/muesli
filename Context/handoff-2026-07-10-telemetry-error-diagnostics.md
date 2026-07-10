# Telemetry Error Diagnostics v2 Handoff

## Branch And PR

- Worktree: `/Users/pranavhari/.codex/worktrees/telemetry-error-diagnostics-v2/muesli`
- Branch: `codex/telemetry-error-diagnostics-v2`
- Draft PR: https://github.com/Muesli-HQ/muesli/pull/306
- Base: `origin/main` at `4e83e8c6673ae602bd2037c5bff603a88c227b5d`

## TelemetryDeck Routing

Organization: `023C8C36-D37F-4D75-AF2D-247A32279D93`

- Production `Muesli`: `7F2B7846-1CB5-4FE6-8ABC-56F217B06A86`
- Dev/Canary `MuesliDev`: `F6448386-6643-4E85-9354-578087725FB0`
- Preprod `MuesliPreprod`: `F12C21C4-3536-4DA2-98D8-40E9C26A51F8`
- Existing `muesli-ios` remains unchanged.

Stable, preprod, dev, and canary builds select their app ID and `muesli.channel` explicitly. Direct source builds have no app ID, use `unconfigured`, and initialize TelemetryDeck with analytics disabled. Every enabled signal also receives `muesli.bundle_id`.

## Diagnostic Contract

- Schema version is `2`.
- Errors use `TelemetryDeck.errorOccurred` with `message: nil`.
- Incident kind, stage, severity, user impact, backend/model, random incident UUID, signature, and area are finite or catalogued values.
- Domain/code are emitted only for exact allowlist matches.
- Unknown errors become `unclassified`; original domain, code, localized description, and user info are omitted from telemetry and generated issues.
- App/build/OS/device analytics use TelemetryDeck SDK fields rather than duplicate diagnostic parameters.
- The incident UUID is included in the generated GitHub issue; TelemetryDeck user/session identifiers are not.
- Historical schema v1 events are unchanged. No backfill, deletion, query utility, export, report artifact, or iOS telemetry change was added.

## Validation

- 14 focused diagnostic/runtime-configuration tests passed.
- Script classifier tests, changed-script `bash -n`, and `git diff --check` passed.
- The complete Swift run executed 1,282 tests. The unrelated timing-sensitive `PasteControllerTests.pasteRestoresClipboard` missed its two-second deadline under full-suite load; all 11 PasteController tests passed when rerun in isolation.
- Before the later request not to rebuild dev, `MuesliDevA` was built and launched with local-only entitlements. Its plist contained the Dev app ID, `dev`, and `com.muesli.dev.a`; the app was subsequently shut down.
- An ephemeral API query confirmed one matching test-mode Dev launch and zero matching Dev-channel events in production. No anonymous user/session identifiers or event payloads were retained.
- Unsigned preprod/stable plist inspection was not completed: a cold home-volume release scratch ran out of space, and an external-cache retry was interrupted. No release script, tag, appcast, GitHub release, or production artifact was created.

## Commits

- `500b715c Route TelemetryDeck by build channel`
- `a3fa48e8 Harden anonymous diagnostic error telemetry`

