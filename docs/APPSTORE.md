# Shipping MeetingIntro to the Mac App Store

The App Store build is a **second target**, not a replacement. `MeetingIntro` keeps
shipping through Homebrew exactly as it does today; `MeetingIntroMAS` is the sandboxed
one. One codebase, two products, so nothing existing users rely on regresses while this
is worked out.

## Why a separate target was unavoidable

| | Homebrew (`MeetingIntro`) | App Store (`MeetingIntroMAS`) |
|---|---|---|
| Sandbox | off | **on** — mandatory, no exceptions |
| Updates | in-app `brew upgrade --cask` | the App Store |
| Signing | Developer ID + notarization | Apple Distribution + provisioning profile |
| Entitlements | `MeetingIntro.entitlements` | `MeetingIntro-MAS.entitlements` |

The in-app updater is **compiled out**, not hidden: `AppUpdater.selfUpdateAvailable` is
false under the `MAS` flag, every update affordance is gone from Settings and the
dropdown, and the About tab says updates arrive through the store. Verified at the binary
level — `strings` finds `brew upgrade --cask` twice in the Developer ID build and **zero
times** in the App Store build. An App Store app may not install software, and the sandbox
could not spawn `brew` in any case.

## What was verified, rather than assumed

- **Audio handoff survives the sandbox.** Switching the system default output device is
  what meeting handoff does, and it was the most likely thing to be lost. Tested in a
  sandboxed bundle with only `app-sandbox` + `audio-input`: reading, **setting** and
  enumerating devices all return `status = 0`.
- **Focus status survives.** `INFocusStatusCenter` behaves identically sandboxed.
- **No `get-task-allow` in the Release build.** That entitlement is an automatic
  rejection; `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO` keeps it out, the same setting that
  already protects notarization.

## Entitlements, and why each is there

| Entitlement | Why |
|---|---|
| `app-sandbox` | Mandatory for the store |
| `personal-information.calendars` | The product |
| `network.client` | Microsoft Graph, AI endpoints, a local Ollama. Outgoing only |
| `files.user-selected.read-write` | Folders picked in an open panel |
| `files.bookmarks.app-scope` | **Required** for the security-scoped bookmarks those panels create — without it saved folders silently stop working after relaunch |
| `device.audio-input` | The microphone track of a recording |
| `assets.movies.read-write` | Recordings default to `~/Movies/MeetingIntro/`, outside the container |

## Certificates: what the first export attempt proved

A Mac App Store submission needs **two** certificates, and neither is the Developer ID one
already on this Mac:

| Certificate | Signs |
|---|---|
| **Apple Distribution** | the `.app` |
| **Mac Installer Distribution** | the `.pkg` that wraps it |

Cloud signing (letting `xcodebuild -allowProvisioningUpdates` mint them) needs an App Store
Connect API key with **Admin** access. A key created with **App Manager** can upload builds
but cannot create certificates, and a key's role cannot be changed after it is generated —
it has to be replaced.

The alternative, which needs no new key: create both in Xcode → Settings → Accounts →
Manage Certificates → **+**. Xcode registers them in the account and installs them into the
login keychain, and the existing App Manager key still handles the upload.

## Still to do — and what each needs

1. **Apple Distribution certificate + Mac App Store provisioning profile.** Only a
   Developer ID certificate exists on this Mac. Needs the Apple Developer account: either
   an App Store Connect API key (Issuer ID, Key ID, `.p8`) so `xcodebuild
   -allowProvisioningUpdates` can mint them, or creating them by hand in the portal.
2. **An app record in App Store Connect** — name, subtitle, primary category, **privacy
   policy URL (required)**, support URL, description, keywords, and screenshots at
   1280×800 or 1440×900.
3. **Privacy nutrition labels.** Calendar data and audio recordings are both collected in
   the App Store's sense, even though everything stays on the device.
4. **Review notes.** Explain that recording is user-initiated and opt-in, that no account
   is required, and that AI features are optional and bring-your-own-key.
5. **Decide what ships.** Two features carry review risk worth weighing before submitting:
   meeting **recording** (Screen Recording permission plus consent expectations), and
   **on-device transcription**, which downloads a ~1.6 GB Whisper model on first use.
6. **Upload.** `xcodebuild -exportArchive` with an App Store export options plist, then
   `xcrun altool`/Transporter. Transporter is not installed on this Mac.

## Build commands

```bash
# Sandboxed App Store build (Debug, ad-hoc signed — for local testing)
xcodebuild -project MeetingIntro.xcodeproj -scheme MeetingIntroMAS -configuration Debug build

# Release, once the distribution identity exists
MEETINGINTRO_MAS_SIGN_IDENTITY="Apple Distribution: …" \
MEETINGINTRO_TEAM_ID=PVRL9W627Q \
MEETINGINTRO_MAS_PROFILE="MeetingIntro App Store" \
xcodebuild -project MeetingIntro.xcodeproj -scheme MeetingIntroMAS -configuration Release archive
```
