# Meeting Intro Mac App - Implementation Plan

## Goal Description
Build a macOS Menu Bar application that monitors the user's calendar for upcoming meetings and triggers a music countdown overlay at a specified time before the meeting starts.

## Setup Requirements
> [!IMPORTANT]
> **Microsoft Graph API Setup**
> To use the Graph API, we need an "App Registration" in the **Microsoft Entra ID (Azure AD)** portal. 
> 1. Go to [portal.azure.com](https://portal.azure.com) and search for "App Registrations".
> 2. Create a new Registration (Name: MeetingIntro, Supported Account Types: "Accounts in any organizational directory and personal Microsoft accounts").
> 3. Add a platform: **Public client/native (mobile & desktop)** -> Redirect URI: `msauth.com.yourname.MeetingIntro://auth` (we'll finalize the bundle ID later).
> 4. Grant API Permissions: `Calendars.Read`.
> 5. Save the **Client ID** (we will need this for the code).

> [!NOTE]
> **Xcode Project Setup**
> Please open **Xcode** and create a new **macOS App** named `MeetingIntro` inside `/Users/oluyinka.oginni/Library/CloudStorage/OneDrive-ServiceNow/Documents/Projects/Meeting_Intro`, ensuring it uses **Swift** and **SwiftUI**. Let me know when you've done this!

## Proposed Changes
The app will consist of:
- **`MeetingIntroApp.swift`**: The main entry point configuring a MenuBarExtra.
- **`SettingsView.swift`**: A UI for the user to configure the countdown duration, select a music file, and select which calendars/meetings to monitor.
- **`CountdownOverlayView.swift`**: The floating edge-to-edge or centralized UI that appears before the meeting.
- **`CalendarManager.swift`**: Background service checking for upcoming events.
- **`AudioManager.swift`**: Service handling the playback of the selected local audio file.

## Verification Plan
### Automated Tests
- N/A for this stage. The core system relies heavily on system APIs (EventKit, AVFoundation) which are better tested manually.

### Manual Verification
1. Open the app and ensure the settings window loads.
2. Grant Calendar access to the app.
3. Schedule a test meeting 2 minutes in the future.
4. Set the app's countdown trigger to "1 minute before".
5. Verify that the countdown overlay appears exactly 1 minute before the meeting and the selected music plays.
