# MeetingIntro — Development & Deployment Guide

## Prerequisites
- macOS 14 (Sonoma) or later
- Xcode 15+ with Swift 5.9+
- Apple Developer account (for signing & calendar entitlement)

## Project Structure
```
MeetingIntro/
├── MeetingIntro/           # Xcode project source
│   ├── MeetingIntroApp.swift
│   ├── CalendarManager.swift
│   ├── AudioManager.swift
│   ├── SettingsView.swift
│   ├── CountdownOverlayView.swift
│   ├── Info.plist
│   └── MeetingIntro.entitlements
├── plan.md
├── AGENT_RULES.md
├── dev.md
├── dev_pattern.md
└── assumptions.md
```

## Build & Run
```bash
# Open in Xcode
open MeetingIntro.xcodeproj

# Or build from CLI (once xcodeproj exists)
xcodebuild -project MeetingIntro.xcodeproj -scheme MeetingIntro -configuration Debug build
```

## Key Configuration
- **Calendar access** requires the `com.apple.security.personal-information.calendars` entitlement.
- **LSUIElement** is set to `true` so the app appears only in the menu bar (no Dock icon).
- User preferences (countdown time, music file, monitored calendars) are stored in `UserDefaults`.

## Deployment
- Archive via Xcode → Distribute App → Developer ID for direct distribution, or App Store.
