# Assumptions

## Calendar Source
- **Assumption:** We support **both** Apple EventKit and Microsoft Graph API as calendar sources. A `CalendarProvider` protocol abstracts the two, and the user selects their preferred source in Settings.
- **Rationale:** EventKit is simpler and works offline for users with accounts in macOS Internet Accounts. Graph API enables access for users who haven't configured their Microsoft account locally or need direct Outlook integration.
- **Status:** ✅ Confirmed by user

## Audio Playback
- **Assumption:** The user selects a local audio file (mp3, m4a, wav) via an `NSOpenPanel` / file picker. We use `AVAudioPlayer` for playback.
- **Status:** ✅ Accepted

## Countdown Overlay
- **Assumption:** The overlay is a borderless, always-on-top SwiftUI window that shows a countdown timer and meeting title.
- **Status:** ✅ Accepted

## Target macOS Version
- **Assumption:** macOS 14 (Sonoma) minimum. This lets us use modern SwiftUI APIs like `MenuBarExtra`.
- **Status:** ✅ Accepted

## App Distribution
- **Assumption:** Initially for personal use — no App Store submission needed. Developer ID signing is sufficient.
- **Status:** ✅ Accepted
