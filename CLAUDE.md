# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

MeetingIntro is a macOS menu bar app (Swift 5.9 / SwiftUI, macOS 14+) that watches the user's calendar and, at configurable thresholds before each meeting, fires some combination of: a floating overlay with background music, a system notification with a Mixkit sound, and a spoken voice reminder.

## Build / run

The Xcode project is generated from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen) — never hand-edit `MeetingIntro.xcodeproj/project.pbxproj`. After changing `project.yml` or adding source files, regenerate:

```bash
xcodegen generate                                                  # rebuild .xcodeproj from project.yml
open MeetingIntro.xcodeproj                                        # open in Xcode (⌘R to run)
xcodebuild -project MeetingIntro.xcodeproj -scheme MeetingIntro -configuration Debug build
```

Bundle ID is `com.oluyinka.MeetingIntro`. `LSUIElement = true` — the app has no Dock icon; it lives only in the menu bar. Hardened runtime is off and code signing is ad-hoc (`-`) in `project.yml`, so the app runs locally without a developer account.

There is no test target. Verification is manual: schedule a calendar event a few minutes out, set a matching countdown trigger, watch the overlay/notification/voice fire.

## Releasing (Homebrew cask)

The app ships via `brew install --cask templegit9/tap/meetingintro`. Cutting a release is `scripts/release.sh <version>` — the script builds Release, signs with Developer ID, notarizes/staples, attaches the zip to a GitHub release, and updates `Casks/meetingintro.rb` in the `templegit9/homebrew-tap` repo. `Casks/meetingintro.rb` in this repo is the canonical template (version + sha are placeholders the script substitutes when copying into the tap). Full one-time setup and per-release runbook in [RELEASING.md](./RELEASING.md). The `Release` config in `project.yml` reads signing identity and team from `MEETINGINTRO_SIGN_IDENTITY` / `MEETINGINTRO_TEAM_ID` env vars (defaults to ad-hoc so Debug builds work without certs).

## Architecture

### App composition (`MeetingIntroApp.swift`)

`@main MeetingIntroApp` owns one `@StateObject` per long-lived service and exposes two scenes: a `MenuBarExtra` (status item) and a `Settings` window. Services are passed into views explicitly rather than read from the environment.

`AppLifecycleManager.observe(...)` is the **single wiring point**. It's called once from `MenuBarView.onAppear` and:
1. Injects `CountdownConfigManager` into `CalendarManager` and `MixkitSoundManager` into `NotificationManager`.
2. Starts the 30-second poll timer (`calendarManager.startPolling()`).
3. Subscribes to `calendarManager.$shouldShowCountdown` → drives `OverlayWindowController.show/dismiss`.
4. Subscribes to `calendarManager.$upcomingMeetings` → fans out to `NotificationManager` and `VoiceReminderManager` based on each trigger's per-channel flags.

If you add a new alert channel (e.g., Slack DM, Hue light), wire it here — don't sprinkle subscriptions across views.

### Calendar abstraction

`CalendarProvider` protocol (`CalendarProvider.swift`) unifies two backends:
- `EventKitProvider` — local macOS calendars via EventKit. Requires the `com.apple.security.personal-information.calendars` entitlement (already in `MeetingIntro.entitlements`).
- `GraphCalendarProvider` — Microsoft 365 via Graph REST API using **OAuth device code flow** (chosen because a sandboxed menu-bar app doesn't have a reliable redirect URI). The user must supply their own Azure App Registration client ID in Settings; token + expiration are cached in `UserDefaults` under `graphAccessToken` / `graphTokenExpiration`.

`MeetingEvent` is the unified model — never leak `EKEvent` or Graph JSON above the provider boundary. `CalendarManager.activeProvider` switches on the user-selected `CalendarProviderType` stored in `UserDefaults["activeProviderType"]`.

### Countdown triggering (`CalendarManager` + `CountdownConfigManager`)

`CalendarManager` is `@MainActor`, polls every 30s, and on each refresh runs `evaluateCountdownTrigger()`. Two rules to preserve:

1. **De-duplication**: `triggeredCombinations: Set<String>` keys on `"\(meetingID)_\(minutes)"`. Without this, every 30-second poll would re-fire the overlay for the same threshold. If you add new trigger logic, use the same key pattern or it will spam.
2. **Per-trigger channel flags**: `CountdownTrigger` has independent `showOverlay` / `sendNotification` / `playVoice` booleans. The user might want "5 min: voice only, 1 min: overlay + music". `CalendarManager` only owns the overlay decision; notification and voice fan-out lives in `AppLifecycleManager`'s `$upcomingMeetings` subscription. Keep that split — overlay is stateful (one at a time), notifications and voice are stateless per fire.

`CountdownConfigManager.triggers` is the source of truth; it auto-persists to `UserDefaults["countdownTriggers"]` via `didSet`. `CalendarManager.countdownMinutesList` is a read-through to it.

### Overlay window (`OverlayWindowController`)

The overlay is **not** a SwiftUI `Window` — it's an `NSPanel` wrapping `NSHostingView(CountdownOverlayView)`, with `.canJoinAllSpaces | .fullScreenAuxiliary` collection behavior and `.floating` level so it appears over fullscreen apps. This is intentional; SwiftUI's window scenes can't reliably do always-on-top + non-activating. Don't replace it with a `Window` scene without verifying behavior over fullscreen Zoom/Teams.

Calling `show(for:)` while a panel already exists is a no-op (the `guard overlayWindow == nil` check) — this is how the de-dup interacts with the window layer.

## Conventions

- **No hardcoded values.** Every tunable (countdown minutes, music file, calendar selection, lookahead interval, Graph client ID, voice template) lives in `UserDefaults`. If you add a feature, add a setting.
- **SwiftUI-first.** Drop to AppKit only where SwiftUI genuinely can't do the job — currently just `OverlayWindowController` (NSPanel) and the `NSOpenPanel` file picker for audio.
- **`@MainActor` on managers that touch published state.** `CalendarManager`, `OverlayWindowController`, `CountdownConfigManager` are all main-actor isolated; respect that when adding async work.
- **Single wiring point.** New cross-service subscriptions go in `AppLifecycleManager.observe`, not in views.
