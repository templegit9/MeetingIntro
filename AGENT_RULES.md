# MeetingIntro — Agent Rules

## Project Overview
**MeetingIntro** is a macOS Menu Bar application built with Swift & SwiftUI. It monitors the user's calendar and triggers a music countdown overlay before meetings start.

## Rules of Engagement
1. **No hardcoding** — all configurable values (countdown duration, music file path, calendar selection) must come from user preferences / `UserDefaults`.
2. **SwiftUI-first** — all UI must be built in SwiftUI; no AppKit unless absolutely required.
3. **Event-driven architecture** — the `CalendarManager` polls/observes the calendar and publishes state changes via `@Published` properties.
4. **Run, don't ask** — execute terminal commands proactively; only ask for permission when a destructive or irreversible action is needed.
5. **Document everything** — update `dev.md`, `dev_pattern.md`, and `assumptions.md` as the project evolves.

## Environment
- **Platform:** macOS 14+ (Sonoma)
- **Language:** Swift 5.9+
- **UI Framework:** SwiftUI
- **Build System:** Xcode / Swift Package Manager
- **Key Frameworks:** EventKit (calendar), AVFoundation (audio)

## Operational Protocols
- Always build and run after making changes to verify correctness.
- Keep the Menu Bar app lightweight — no Dock icon unless user requests one.
- Use `LSUIElement = true` in Info.plist so the app lives only in the menu bar.
