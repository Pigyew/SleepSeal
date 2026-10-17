# 0.2.2 Beta reliability work / 可靠性改进

This branch implements the review of `2d7c5b2`. It does not install, sleep the test machine, quit real applications, or publish a release during verification. Current signing remains ad-hoc, without notarization.

## Recovery and compatibility

`PowerPreferenceBackup` keeps the existing `original` and `lastWritten` fields and accepts existing JSON arrays. `lastWritten` now means the last value confirmed by a system read. Optional `pendingWrite` stores `previousValue`, `targetValue`, and `phase` (`applying`, `restoring`, `rollingBack`). Journal preparation precedes the write; confirmation precedes committing the new value. Restart recovery accepts either recorded transaction value and preserves an unrelated external value.

The valid transient recovery engine initializes independently of optional settings. A damaged configuration, future configuration schema or damaged persistent backup pauses new protection/settings writes while allowing verified recovery. The bad files are not deleted or silently reset. Repair the saved settings separately; reinstalling does not rewrite user settings.

## Automated verification

Run `bash test.sh`. The suite contains 19 isolated Swift test executables, a bilingual key/format checker and 32 Python release/installer checks. All hardware, app termination and uninstall adapters in these checks are mocked or explicitly injected. Installer script copies run only with temporary paths and fake system commands.

Important new coverage includes:

- Twelve durable interruption points across initial write, repeated write, restore and rollback, followed by restart recovery and external-value preservation.
- Damaged/future settings, valid pending recovery, service-startup preference fallback and unchanged bad-file bytes.
- Queued old unlock callbacks crossing a new sleep or re-lock; current-event recovery still works.
- More than 32 blockers, unified deadline, partial inventory, cancellation, new blockers and save prompts.
- Native temporary-file uninstall staging, symlink/conflict rejection, rollback and cleanup-only retries.
- Deferred onboarding, explicit reopening, recovery-only controls, busy cancellation and bilingual error presentation.

Run native window checks only in mock mode:

```sh
build/SleepSeal.app/Contents/MacOS/SleepSeal --ui-self-test "$PWD/build/gui-checks"
```

The optional CI GUI job needs a trusted ARM64 macOS runner labeled `sleepseal-gui`, running as its logged-in graphical user. Ordinary CI runs the headless dashboard/localization tests without that runner. A screenshot or in-process accessible action is not a complete manual VoiceOver audit.

## Background-work budget

The stable hidden timer changes from 10 to 60 seconds. Pending recovery and a visible dashboard retain 10-second checks. Display-only capability and helper-authorization reads are cached for up to five minutes; every actual privileged write still checks its installation/authorization boundary. Ownership release retries until successful, then stops until another completed recovery cycle.

Under stable, healthy, hidden operation with app-quit preparation off, the old code scheduled about 1,800 external command calls/hour. The new steady-state schedule is about 144/hour (120 settings/assertion reads plus 24 capability/authorization reads), excluding startup and retries. These are static call-budget calculations, not measured battery savings. Pointer tests verify 10,000 outside-corner motions produce one initial queue submission while entry/exit transitions remain observable.

Before claiming real resource or battery improvement, compare the same machine/OS/settings with the dashboard closed and quit requests off: record process CPU time, wakeups, child launches, and event-to-handling delay for equal intervals, then repeat matched overnight trials. Keep AC/battery state, peripherals, network conditions, duration and starting battery charge comparable; record exceptions rather than dropping unfavorable runs. The implementation tests do not establish production CPU/wakeup or overnight results.

## Build and release

`VERSION` is the single build-version source. Build starts from a clean app bundle, snapshots source hashes, checks that sources stayed unchanged, and records compiler/toolchain and output hashes. Packaging independently verifies architecture, target, version, signatures and source/output integrity. The installer remains fixed-path and is expanded for inspection without installation.

Only an existing matching `v*` tag can publish a Beta. Release downloads the immutable artifact ID from that same successful workflow run, rechecks source/commit/run/package/checksum provenance, and uploads those original bytes without rebuilding. This work creates no tag and makes no release. Do not describe local ad-hoc signatures as verified developer identity.

## Real-device release gates / 实机发布门槛

- Short system/display sleep, lock-screen waiting and actual unlock recovery; test an originally disabled radio and a partial recovery failure.
- Lid sleep versus external-display clamshell operation; rapid sleep/wake and re-lock; multiple accounts and restart with pending state.
- Installer upgrade, interrupted install/uninstall and shared installation retention in a disposable test account or VM.
- Ordinary app refusal/save prompts on a test workload; never infer these results from simulated quit requests.
- Supported macOS/device matrix, manual VoiceOver traversal, matched overnight power measurements, Developer ID signing and notarization.

本分支完成代码修复与隔离验证，不把模拟结果解释为真实节电量、全面兼容或正式安全认证。实机睡眠、过夜耗电、人工辅助功能及签名公证仍是稳定版前的独立门槛。
