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

---

## Review rejection — 2.20.6 build 202609112321 (15 September 2026)

Submission `ee7a8be6-2fda-4d0f-a77e-f94e505bc00b`. Two issues, both **guideline 2.4.5(i)**,
both in the recording feature. Fixed together; notes here so neither recurs.

### 1. User files were written into the app container

> "The app saves user data to the app's container, which is not user accessible… the
> container is not for user documents."

**Cause.** `RecordingConfig.resolveSaveDirectory()` fell back to
`FileManager.urls(for: .moviesDirectory)` when the user hadn't picked a folder. That is
`~/Movies/MeetingIntro/` in the Developer ID build — a real, visible folder — but under
the sandbox it resolves to `~/Library/Containers/com.oluyinka.MeetingIntro/Data/Movies`,
which no user will ever find in Finder. Recordings, transcripts and notes all landed
there, because the `.transcript.md` / `.notes.md` sidecars are written next to the `.m4a`.

**Fix.** `resolveSaveDirectory()` now returns `URL?`, and
`RecordingConfig.requiresChosenDirectory` is true under `#if MAS`. In the sandboxed build
there is **no implicit default** — recording refuses to start and says why, Settings shows
an orange "No folder chosen yet" with a prominent **Choose Folder…**, and the picked
folder arrives through the existing `NSOpenPanel` + security-scoped bookmark path that
`files.user-selected.read-write` and `files.bookmarks.app-scope` already cover.

The Developer ID build is **unchanged** and keeps its `~/Movies/MeetingIntro/` default,
which is correct there precisely because that build isn't sandboxed.

**Do not reintroduce a fallback directory in the MAS build.** A default that the user
cannot see is the rejection.

### 2. An entitlement with no matching functionality

> `com.apple.security.assets.movies.read-write`

**Cause.** Added on the assumption the sandboxed build would write to the real
`~/Movies`. It never did — see above — so the entitlement was dead weight, and Apple
checks for exactly that.

**Fix.** Removed. Every recording path now goes through a user-selected folder, which is
covered by `files.user-selected.read-write`. The entitlements file carries a comment
saying not to add it back.

### Entitlements after the fix

`app-sandbox`, `personal-information.calendars`, `network.client`,
`files.user-selected.read-write`, `files.bookmarks.app-scope`, `device.audio-input`.
Six, each with a live call path.

### Note for testers

A TestFlight tester who recorded with the rejected build has those files inside the old
container. Nothing migrates them — the fix changes where *new* recordings go. Only
internal testers ever ran that build, so no shipped user is affected.
