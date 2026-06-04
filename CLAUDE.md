# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

MeetingIntro is a macOS menu bar app (Swift 5.9 / SwiftUI, macOS 14+) that watches the user's calendar and, at configurable thresholds before each meeting, fires some combination of: a floating overlay with background music + a one-click Join button + a meeting context panel, a system notification with a Mixkit sound, and a spoken voice reminder. Firings are gated by live context (in another call, Focus on, screen-sharing, fullscreen app), the app can hand off audio output + Focus state on meeting start/end, and it can auto-record meetings with detected conference links to `.m4a` files in `~/Movies/MeetingIntro/`.

Distributed via Homebrew cask: `brew install --cask templegit9/tap/meetingintro`. Notarized + stapled.

## Build / run

Xcode project is **generated** from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen) — never hand-edit `MeetingIntro.xcodeproj/project.pbxproj`. **Info.plist is also generated** from `project.yml`'s `info.properties`; direct edits to `MeetingIntro/Info.plist` get overwritten on every `xcodegen generate`. Add new plist keys to `project.yml`.

```bash
xcodegen generate                                                  # regenerate .xcodeproj + Info.plist
open MeetingIntro.xcodeproj                                        # Xcode (⌘R to run Debug)
xcodebuild -project MeetingIntro.xcodeproj -scheme MeetingIntro -configuration Debug build
```

Bundle ID is `com.oluyinka.MeetingIntro`. `LSUIElement = true` — no Dock icon, menu bar only. Debug builds use ad-hoc signing (`-`) and no hardened runtime so they run without certs. Release builds use Developer ID + hardened runtime + `--timestamp` + `--options runtime` for notarization.

No test target. Verification is manual: open Settings → Countdown → **Test Countdown Overlay** for an in-app preview that exercises every overlay feature, or schedule a real calendar event a few minutes out and watch the live behavior.

## Releasing (Homebrew cask)

`scripts/release.sh <version>` does the full pipeline: regenerate project → build Release → sign → notarize → staple → re-zip → GitHub release → push cask to `templegit9/homebrew-tap`. Secrets load from `.env.release` at the repo root (gitignored). Full runbook in [RELEASING.md](./RELEASING.md).

GitHub release notes are auto-generated: a "What's changed since <previous tag>" section is prepended to the install instructions from the commit subjects since the previous tag, grouped into New / Fixes / Other by conventional-commit prefix, with `chore: bump version` and `docs(claude-md)` bookkeeping filtered out. Capped at 30 commits. Commit subjects are themselves user-facing — write them accordingly. **The auto-generated list is a floor, not a ceiling: for feature-level releases, hand-augment the notes after shipping (`gh release edit <tag> --notes ...`) to enumerate the user-facing enhancements as bullets — a subject line can't carry them.** (Learned on v2.3.2, where the persistent-cancellation-notice enhancement set shipped as half a subject line until retro-edited.)

**Signing gotchas that have actually bitten us** — keep these intact:
- `CODE_SIGN_ENTITLEMENTS: MeetingIntro/MeetingIntro.entitlements` in `project.yml` base settings. **Required** because `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO` in Release turns off Xcode's automatic entitlement injection. Without the explicit path, the signed binary has zero entitlements and every capability (calendar, network, file pick) silently fails at runtime, regardless of TCC state. We shipped v1.0.0 through v2.0.4 with this bug; v2.0.5 fixed it.
- `OTHER_CODE_SIGN_FLAGS: "--timestamp --options runtime"` in Release. Notarization rejects signatures without a secure timestamp.
- `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO` in Release. Otherwise Xcode injects `com.apple.security.get-task-allow` (the debugger-attach entitlement) and notarization rejects it.
- `Info.plist` uses `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)` substitutions so the version the release script passes via `xcodebuild MARKETING_VERSION=$VERSION` actually reaches the bundle.

## Architecture

### App composition (`MeetingIntroApp.swift`)

`@main MeetingIntroApp` owns one `@StateObject` per long-lived service and exposes two scenes: `MenuBarExtra` and `Settings`. Services pass into views explicitly, not via the environment. The `audioRouter` / `handoffConfig` / `handoffCoordinator` trio is constructed together in `init()` because the coordinator needs references to the other two.

`AppLifecycleManager.observe(...)` is the **single wiring point**. Called once from `MenuBarView.onAppear`:
1. Wires `CountdownConfigManager` into `CalendarManager`, `MixkitSoundManager` into `NotificationManager`, attaches `handoffCoordinator` to `CalendarManager`.
2. Defines one `@MainActor` `decide` closure: `(CountdownTrigger) -> ReminderDecision` that calls `ReminderEscalationPolicy.decide` with the live context snapshot. **The same closure is used for all three channels** (overlay, notification, voice) — single source of truth for the gating decision.
3. Wires the overlay channel via `calendarManager.shouldFireOverlay = { decide($0).showOverlay }`.
4. Starts polling (must happen *after* the hook is set so the first poll uses the policy).
5. Subscribes to `$shouldShowCountdown` for the overlay window, and to `$upcomingMeetings` for notification + voice fan-out (each gated by `decide(trigger)`).

If you add a new alert channel, wire it through `decide` here — don't sprinkle subscriptions across views.

### Calendar abstraction

`CalendarProvider` protocol (`CalendarProvider.swift`) unifies two backends:
- `EventKitProvider` — local macOS calendars via EventKit. Requires the `com.apple.security.personal-information.calendars` entitlement (declared in `MeetingIntro.entitlements`, wired via `CODE_SIGN_ENTITLEMENTS`).
- `GraphCalendarProvider` — Microsoft 365 via Graph REST API using **OAuth device code flow** (a sandboxed menu-bar app doesn't have a reliable redirect URI). The Graph access token + expiration are stored in **Keychain** via `KeychainStore` (`MeetingIntro/Storage/`); the legacy UserDefaults values auto-migrate on first read after upgrade. Client ID stays in UserDefaults (not a credential).

`MeetingEvent` is the unified model. **Never leak `EKEvent` or Graph JSON above the provider boundary.** Fields: `id, title, startDate, endDate, calendarName, location?, isAllDay, url?, notes?, attendeeNames, attendeeCount, organizerName?, isCancelled`. The provider boundary HTML-strips Graph `body.content` to plain text once, runs `ConferenceLinkExtractor.bestURL(...)` to pick the join link, and applies `CancellationTitlePrefix.matches(...)` as a fallback for cancellations whose calendar source rewrites the title to `Canceled: ...` / `Cancelled: ...` but doesn't set the structured status flag (common with older Exchange forwarding).

**Three call sites** construct `MeetingEvent`: `EventKitProvider`, `GraphCalendarProvider`, and the `Test Countdown Overlay` preview in `SettingsView`. When you add a field, update all three.

`CalendarManager` (@MainActor) polls every 30s and also subscribes to `EKEventStoreChanged` so granting calendar access in System Settings triggers a refresh without an app restart. `errorMessage` is cleared at the top of `refreshEvents()` and re-set only if a new error occurs — so stale "access denied" messages clear automatically once the user grants access.

### Countdown triggering

`CalendarManager.evaluateCountdownTrigger()` keeps two rules:

1. **De-duplication**: `triggeredCombinations: Set<String>` keyed `"\(meetingID)_\(minutes)"`. Without this, every 30s poll would re-fire. Same key pattern for new trigger logic.
2. **Policy hook**: the `shouldFireOverlay: ((CountdownTrigger) -> Bool)?` closure is consulted before setting `shouldShowCountdown = true`. `AppLifecycleManager` injects a closure that consults `ReminderEscalationPolicy`. Default (closure nil) is to respect `trigger.showOverlay` directly.

`CountdownConfigManager.triggers` is the source of truth for which thresholds are enabled and which channels each fires; auto-persists to UserDefaults via `didSet`.

### Cancellation handling (v2.2.0)

Cancelled meetings are first-class: notify once on detection, suppress all original-start-time channels (overlay, notification, voice, auto-record).

- **Detection** lives in the providers (`EKEvent.status == .canceled` / Graph `isCancelled`, with `CancellationTitlePrefix` as fallback). The flag rides through on `MeetingEvent.isCancelled` so downstream code never has to ask the calendar source again.
- **`CalendarManager` owns the persistence**: `notifiedCancellationIDs` (we've already fired the notification) and `dismissedCancellationIDs` (user clicked Dismiss on the dropdown badge). Both persist to UserDefaults so an overnight cancellation is still visible in the dropdown the next morning — Jon's "someone in Japan cancelled while I was asleep" case. `pruneCancellationState` drops IDs whose corresponding meeting has ended, keeping the sets bounded.
- **Fan-out** is in `AppLifecycleManager.observe`: a dedicated `$upcomingMeetings.sink` runs **before** the regular reminder fan-out, so a freshly-cancelled meeting in the same refresh cycle never fires both a cancellation notification AND a stale reminder. Each cancelled meeting matched against `notifiedCancellationIDs` → either notify + mark, or skip.
- **Suppression** is symmetric across every reminder channel: `CalendarManager.evaluateCountdownTrigger`'s outer `where` adds `!event.isCancelled`; `AppLifecycleManager`'s reminder fan-out adds the same gate; `MeetingRecordingCoordinator.shouldRecord` adds `&& !meeting.isCancelled`. Cancelled meetings are still added to `todaysMeetings` (the menu bar shows them struck-through) and to `meetingsCurrentlyRunning` excludes them so the handoff coordinator doesn't switch audio for a meeting that isn't happening.
- **Today view in `MenuBarView`**: replaces the old "Next Meeting" header. Renders `todaysMeetings` as compact rows, cancelled ones get `.strikethrough()` + a red `xmark.circle.fill`. Above the list, when `pendingCancellations` is non-empty, a "Cancelled Today" section shows each one as a clickable menu Button that dismisses it via `calendarManager.dismissCancellation(id)`. Display capped at 8 rows + "+N more" overflow. **NSMenu rendering constraint**: `MenuBarExtra(.menu)` flattens SwiftUI containers — an `HStack` of `Text`s becomes one menu item *per Text*, splitting rows across lines. Every meeting row is therefore built as ONE concatenated `Text` (`meetingRowText(for:)`: time + title + status glyph via `Text + Text`), which is the only reliable way to get a styled single-line row inside NSMenu. `textCase`/`tracking`/`padding` modifiers return `some View` (not `Text`) and re-trigger the splitting — avoid them in menu content.
- **User settings (v2.2.6)** in the Countdown tab's "Cancelled Meetings" section: `cancellationNotifyEnabled` + `cancellationPlaySound` (on `NotificationManager`, default on), `cancellationShowInTodayView` (@AppStorage, default on, display-side filter only), `cancellationShowOverlay` (@AppStorage, **default off**). The fan-out in `AppLifecycleManager` always calls `markCancellationNotified` even when notify is off — "notified" means "seen", which the badge and dedup depend on. Suppression of original-start-time reminders is hardcoded, deliberately not a setting.
- **Cancellation notice is a persistent acknowledgment surface, NOT a toast (v2.3.2).** `CancellationOverlayView` renders the persisted `pendingCancellations` list (each row has its own Dismiss); **no auto-dismiss timer** — the original 12s toast self-expired before anyone saw it (and `Task.sleep` counts wall-clock time through system sleep, so a notice shown pre-lid-close was already dead at wake). Display is **state-driven**: a `CombineLatest($pendingCancellations, $snapshot)` subscriber in `AppLifecycleManager` shows/hides `OverlayWindowController.showCancellationCenter(_:onDismissItem:)` (idempotent on the pending ID set). Overnight cancellations are on screen at lid-open and survive restarts until acknowledged. Overlay Dismiss calls the same `dismissCancellation(id)` as the dropdown badge — one acknowledgment system. **Smart-context hold**: hidden while in a call (gated on `suppressWhenInCall`) or screen-sharing; reappears automatically when the hold clears.
- **Both overlay panels force `NSAppearance(named: .darkAqua)` (v2.3.2)** — they're dark-designed (hardcoded white text on `.hudWindow` blur), and that material follows system appearance: without the forced appearance, light mode renders it light and the white text is invisible. Any new always-on-top panel with the dark design must set this (the QuickAdd panel achieves the same via `.colorScheme(.dark)`).

### Smart context detection (`MeetingContext/`)

Four detectors + monitor + pure-function policy:
- **`FrontmostAppDetector`** — `NSWorkspace.didActivateApplicationNotification` push-driven. Bundle ID match against a video-conf allowlist; fullscreen check via `CGWindowListCopyWindowInfo` window-bounds.
- **`MicrophoneDetector`** — CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere` listeners on each input device. **No mic prompt** because we never open the device for capture.
- **`FocusModeDetector`** — `INFocusStatusCenter` (read-only API). Polls every 10s; `.denied` is treated as "Focus off." Requires `NSFocusStatusUsageDescription` in `project.yml`.
- **`ScreenCaptureDetector`** — heuristic: known-recorder bundle ID running OR (conference app frontmost AND mic in use). **No public macOS API exposes "is being captured by another process"** — `CGDisplayIsCaptured` is deprecated on macOS 14+, `SCShareableContent` only lists shareable resources, not capture state. The heuristic is the best we can do without Screen Recording permission. The detector takes closures for frontmost-bundle-ID and mic-in-use so it stays decoupled; `MeetingContextMonitor` wires them and pokes `refresh()` on every input change.

`MeetingContextMonitor` aggregates into `MeetingContextSnapshot`. `ReminderEscalationPolicy.decide(trigger, context, config)` is pure: evaluates rules top-to-bottom (most aggressive first: in-call → suppress-all; Focus on → visual-only; sharing → no voice; fullscreen → escalate), returns `ReminderDecision`. `SmartConfigManager` persists the four user toggles individually.

### Overlay window (`OverlayWindowController`)

The overlay is **not** a SwiftUI `Window` — it's an `NSPanel` wrapping `NSHostingView(CountdownOverlayView)`, with `.canJoinAllSpaces | .fullScreenAuxiliary` collection behavior and `.floating` level so it appears over fullscreen Zoom/Teams. SwiftUI's window scenes can't reliably do always-on-top + non-activating.

Panel height is computed at `show(for:)` time: **720pt** when `CountdownOverlayView.shouldShowDetailsPanel(for:threshold:)` says the details panel will render, **560pt** otherwise. Same function is also called from the SwiftUI view itself, so the size and visibility decisions stay in sync.

Calling `show(for:)` while a panel exists is a no-op (`guard overlayWindow == nil`).

**Countdown lifecycle (v2.3.3): the overlay does NOT close at meeting start.** At 00:00 it flips to "MEETING IN PROGRESS" and counts negative in red ("since start") until the user joins (Join also dismisses — joining is the acknowledgment), dismisses, or the meeting's **end** time passes (safety net, enforced both in the view's timer and in `CalendarManager.evaluateCountdownTrigger` — the poll-side auto-dismiss checks `endDate`, not `startDate`; changing it back to start-time would silently kill the negative-countdown feature on the next 30s poll).

### System handoff (`SystemHandoff/`)

Runs on meeting start/end (currently-running meetings, not just upcoming):
- **`AudioRouter`** — CoreAudio wrapper around `kAudioHardwarePropertyDefaultOutputDevice`. Lists output devices with their **UID** (stable across reboots) and transport type (so Bluetooth is identifiable). The Handoff config persists device *UIDs*, never `AudioDeviceID` (CoreAudio reassigns those on disconnect).
- **`FocusModeController`** — invokes user-installed Shortcuts via `shortcuts://run-shortcut?name=...` URLs. `INFocusStatusCenter` is read-only, AppleScript needs the Automation entitlement, Shortcuts is the only blessed escape hatch for a sandboxed app. After invocation, polls `INFocusStatusCenter` for up to 3s to verify; reports `.verified` / `.unverified` / `.noFocusPermission`. Users must install two named Shortcuts: `MeetingIntro – Start Focus` and `MeetingIntro – End Focus`.
- **`HandoffStateSnapshot`** — `Codable`, persisted to UserDefaults. Captures `(meetingID, endTime, priorOutputDeviceUID, priorFocusWasActive)`. The coordinator restores from this snapshot on the meeting-end event, and on next launch if a stale snapshot exists with `endTime <= now` (crash-recovery path).
- **`MeetingHandoffCoordinator`** subscribes to set-diff on `CalendarManager.$meetingsCurrentlyRunning`. On enter: snapshot + switch audio + invoke Focus. On exit: restore.

### Meeting recording (`Recording/`)

Same set-diff pattern as `SystemHandoff/`, gated on `meeting.url != nil` so meetings without a detected conference link are skipped:

- **`RecordingController`** — owns **two parallel audio pipelines** writing to a single `.m4a`. `SCStream` (ScreenCaptureKit) for **system audio** — the only public macOS API that captures app playback without a virtual loopback driver. `AVCaptureSession` + `AVCaptureAudioDataOutput` for the **microphone**. We'd prefer SCStream's own `captureMicrophone` (one stream, one writer), but that's macOS 15+ and our deployment target is 14.0. SCStream requires video config even when we only want audio, so we set a 2×2 placeholder at 1 fps and never wire up a video output. Output: dual-track `.m4a` — most players (QuickTime, VLC, Finder Preview) mix the two tracks on playback.
- **`SessionStarter`** — small threadsafe coordinator that calls `writer.startSession(atSourceTime:)` exactly once, using the PTS of whichever pipeline produces the first sample. Both pipelines wait on it before appending.
- **`RecordingSession`** — `Codable`, persisted to `UserDefaults["recordingSession"]`. Same crash-recovery pattern as `HandoffStateSnapshot`. On launch, if `meetingEndTime <= now`: partial files under 100 KB get deleted (empty container, no recoverable audio); larger files are left for manual recovery via QuickTime or ffmpeg (we can't `finishWriting()` from a different process).
- **`RecordingConfig`** — `isEnabled`, `hasAcceptedDisclaimer` (persists across off/on toggles so the legal disclaimer modal only fires once), `saveDirectoryBookmark: Data?` (security-scoped bookmark for user-picked non-default save folders; nil → defaults to `~/Movies/MeetingIntro/`).
- **`MeetingRecordingCoordinator`** subscribes to `CalendarManager.$meetingsCurrentlyRunning` set-diff. Gates on `config.isEnabled && config.hasAcceptedDisclaimer && meeting.url != nil`. Errors surface via `lastError: String?` for the Settings UI to render.

Permissions required (added to `project.yml` `info.properties` so they land in the generated `Info.plist`):
- `NSMicrophoneUsageDescription` — prompted on first `AVCaptureSession.startRunning()`.
- `NSScreenCaptureUsageDescription` — prompted on first `SCStream.startCapture()`.
- Entitlements: `com.apple.security.device.audio-input` (sandboxed mic); `com.apple.security.files.user-selected.read-write` (was read-only; upgraded so the folder picker bookmark works).

Filename format: `YYYY-MM-DD HHmm - {sanitized title}.m4a`. Sanitization strips `/\:?<>|*"`, collapses whitespace, truncates to 80 chars, suffixes `-2`/`-3`/… on collision.

**Visibility and lifecycle (v2.1.1):**
- Menu bar icon swaps to `record.circle.fill` while recording — at-a-glance signal that the active capture belongs to MeetingIntro vs some other app.
- Menu bar dropdown shows "🔴 Recording" + meeting title + inline Stop button at the top — manual stop without opening Settings.
- `NotificationManager.sendRecordingStartedNotification` posts a one-shot per meeting when recording begins (key `recording_started_<meeting.id>`).
- **Graceful app quit:** `AppDelegate.applicationShouldTerminate` returns `.terminateLater` while a recording is in progress, awaits `coordinator.stopManually()`, then calls `reply(toApplicationShouldTerminate:)`. Without this the `AVAssetWriter` is force-killed mid-write and the file is unrecoverable. The delegate is wired via `NSApplicationDelegateAdaptor`; `AppLifecycleManager.observe` injects the coordinator weak reference once the `@StateObject`s exist.
- **Sleep/wake:** `NSWorkspace.willSleepNotification` → `controller.stop()` so the file is finalized before macOS suspends `SCStream` and `AVCaptureSession`. `NSWorkspace.didWakeNotification` clears `runningMeetingIDs` + the snapshot and reconciles against the calendar's currently-running meetings, so a meeting that's still going across a sleep gets a fresh recording in a new file. `AVAssetWriter` has no resume API; a new file is the cleanest recovery path.

### Quick Add — text-to-calendar (`QuickAdd/`, v2.3.0)

First **calendar-write** feature. Menu bar → "New Event…" opens a palette anchored beneath the status item (located by scanning `NSApp.windows` for a `StatusBarWindow` class — SwiftUI exposes no `NSStatusItem`); typing parses live into an `EventDraft`, Enter creates via EventKit.

- **Hybrid parsing**: `DetectorParser` (NSDataDetector, on-device, always works) + optional `OpenRouterParser` (misnamed slightly — it speaks to **any OpenAI-compatible endpoint**; key in **Keychain** under `openRouterKey`). The service shows the detector result instantly, then upgrades to the LLM result when it lands; every LLM failure silently falls back. **The LLM is an upgrade, never a gate.**
- **Provider presets** (`QuickAddProvider` enum, v2.3.1): OpenRouter / Groq / Gemini / Cerebras / Ollama-local / custom. Switching presets auto-fills the endpoint AND resets the model to that provider's suggested default — model IDs aren't portable. Ollama needs no key (`llmEnabled = hasLLMKey || apiBaseURL != default`); the Authorization header is only sent when a key exists. The Settings **Test button** runs a fixed sample phrase through the configured endpoint+model and surfaces the exact failure — `ParseFailure.reason` carries timeout/429/401/non-JSON specifics. Reasoning models are a known trap: too slow for the 6s parse window and they wrap output in thinking text instead of `message.content` JSON.
- **Assumptions contract** (v2.3.1): `EventDraft.assumptions: [String]` — the LLM prompt REQUIRES listing every invented detail ("No start time given — assumed 9:00 AM"); the detector flags date-only phrases via a clock-time regex on the matched substring. The preview renders each as an orange warning. A silent guess must never land on the calendar unnoticed.
- **`KeyablePanel`** (`canBecomeKey = true`) — the overlay panels deliberately can't take focus; Quick Add needs a focused text field. Dismisses on Esc / `didResignKey` / after create.
- **Write path respects the provider boundary**: `EventKitProvider.createEvent(from:calendarID:)` builds + saves the `EKEvent` internally; `CalendarManager.createEvent` delegates and refreshes. Writes are EventKit-only regardless of the active read provider — Graph write needs an OAuth scope upgrade (`Calendars.Read` → `ReadWrite`) and is a later phase.
- **EventKit cannot add attendees/send invites programmatically** (Apple blocks it) — drafts never carry invitees; the Settings copy says so.
- The existing Full Access calendar grant covers writes — no new permission prompt or entitlement.

### What's New tab (`ReleaseNotesManager.swift`, v2.3.0)

Settings → Help → What's New fetches release notes live from the public GitHub Releases API (unauthenticated, 60 req/hr is plenty), strips the "## Install" boilerplate, caches the last good response in UserDefaults (1h TTL) so it renders offline. Changelogs stay current without app updates because the release script auto-generates the notes.

## Conventions

- **No hardcoded values.** Every tunable lives in `UserDefaults` (or Keychain for credentials). If you add a feature, add a setting.
- **SwiftUI-first.** Drop to AppKit only where SwiftUI genuinely can't do the job — currently `OverlayWindowController` (NSPanel), `NSOpenPanel` for audio picking, and `NSWorkspace.shared.open` for URLs/Shortcuts.
- **`@MainActor` on managers that touch published state.** All managers in `MeetingContext/` and `SystemHandoff/` are main-actor isolated. CoreAudio listeners dispatch back to main via `Task { @MainActor in ... }`. `deinit` cannot call `@MainActor` methods — for singletons that live for app lifetime, just skip explicit cleanup.
- **Single wiring point.** New cross-service subscriptions go in `AppLifecycleManager.observe`.
- **`.entitlements` and `Info.plist` are configured in `project.yml`, not edited directly.**
