# Maintenance
Update after relevant changes; keep the handoff current and the newest five change entries.

## Current handoff
- Assigned worktree: wt/t_e12ec6ee; no commits, installation, or launch authorized.
- Exact-bundle CUA exclusion implemented and regression/build gates passed. Manual MacBook GUI QA remains pending (checklist below).

## Behaviors to preserve
- User exclusions persist under SwitchboardExcludedApps and replace defaults when present.
- Window enumeration preserves CGWindow Z-order and does not deduplicate app windows.
- Exclude exact bundle `com.trycua.driver` independently of saved owner-name exclusions. Preserve other accessory apps and unknown/nil bundles unless excluded by user owner name.

## Verification
- Safe build: `APP_PATH="$PWD/.build/Verification/Switchboard.app" ./build.sh` (never --launch for this task).
- Baseline build and ad-hoc signing pass on Swift 6.4/macOS 27, with concurrency and deprecation warnings.
- Regression: `bash Tests/run-window-owner-exclusion.sh` compiles the real `AltTabManager.swift` policy without launching NSApplication or accessing user preferences.
- Typecheck: `swiftc -typecheck main.swift AltTabManager.swift AudioRecorder.swift AudioDownloader.swift DictationManager.swift -framework Cocoa -framework CoreGraphics -framework AVFoundation -framework ScreenCaptureKit -framework ApplicationServices`.
- Task logs, compiler caches/temp files, test binary, and verification app stay under `.build/`; no installed application was modified.

## Investigation
- Live CuaDriver metadata: bundle `com.trycua.driver`, activation policy accessory (1), from Hermes cua-driver 0.21.0. Bundle ID also verified from Info.plist.
- No driver-owned window is present in this Mac Mini's on-screen or all-window CGWindow lists. Actual visible-window metadata/reproduction on the MacBook remains unverified.
- Root cause before correction: getWindows used CG owner-name exclusions only; getVisibleApps lists regular apps only. Thus the accessory driver is not offered in the hide-app menu, and adding a default name alone would not cover persisted settings.

## Recent changes

### 2026-10-30: Hide CUA Driver from Option-Tab
- Changed: `AltTabManager.getWindows` resolves the existing CG owner PID through `NSRunningApplication.bundleIdentifier`; a small static predicate combines exact CUA identity with the existing owner-name exclusions. No defaults migration, activation-policy exclusion, or dependency added.
- Tests: `Tests/WindowOwnerExclusionTests.swift` and `Tests/run-window-owner-exclusion.sh`; empty/custom saved exclusions, differing driver names, ordinary/unknown/nil bundles, user name exclusions, and near-match bundle IDs.
- RED: runner exited 1 against the original name-only policy extracted unchanged before correction: 12/15 passed; all three CUA cases returned visible instead of excluded. Log: `.build/Verification/window-owner-red.log`. This reproduces the policy defect, not the GUI symptom.
- GREEN: same runner exited 0, 15/15 passed. Log: `.build/Verification/window-owner-green.log`.
- Gates: full-source typecheck exited 0 (`.build/Verification/typecheck.log`); safe build command above exited 0, including ad-hoc signing (`.build/Verification/build.log`). Existing concurrency/deprecation warnings left unchanged.
- Review: OMP performed bounded self-review; Hermes orchestrator independently inspected the full production diff, tests, runner, and callers, and reran regression (15/15), full-source typecheck, local build, strict signature verification, and `git diff --check` (all exit 0). No blocking code findings. CG alpha/layer/size filters, append order/multiple windows, and preference persistence remain unchanged. Human review and MacBook GUI QA are pending.

## Manual MacBook QA — NOT RUN
- With persisted exclusions and an active driver window, verify CUA Driver is absent from Option-Tab.
- Verify ordinary apps and multiple windows remain visible and selectable.
- Verify hide/unhide owner-name preferences persist across relaunches.
- Verify refresh and Space transitions do not reintroduce the helper.
- Remaining risk: no live driver window was available for UI verification. Failed PID/app lookup produces a nil bundle and deliberately retains prior name-only behavior.
