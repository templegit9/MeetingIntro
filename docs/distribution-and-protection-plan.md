# Plan — Protect the source (no forks) + ship on the Mac App Store

> Status: **planning only — not started.** Decide the open questions (§7) before executing.
> Not legal advice; confirm anything consequential with a lawyer / Apple's current guidelines.
> Written 2026-06-15.

## 0. Goal

Two objectives the user wants:
1. **Protect the app — make it NOT forkable** (proprietary, source not freely reusable/visible).
2. **List it on the Mac App Store** (in addition to, or instead of, the current Homebrew cask).

These are independent tracks (A = protection, B = App Store) that can ship separately.

## 1. Current state (the starting point)

- **Repo:** `templegit9/MeetingIntro` is **PUBLIC**, with **no LICENSE** (GitHub shows no license → effectively "all rights reserved", but the **source is visible to everyone**).
- **About line:** "© <year> TempleGit. All rights reserved."
- **Distribution:** Homebrew cask `templegit9/tap/meetingintro` (separate public tap repo). `scripts/release.sh` builds **Release** with **Developer ID + hardened runtime + `--timestamp --options runtime`**, notarizes, staples, attaches the `.zip` to a **public GitHub Release**, and updates the cask.
- **NOT App-Sandboxed.** `MeetingIntro.entitlements`: `personal-information.calendars`, `network.client`, `files.user-selected.read-write`, `device.audio-input`. **No `com.apple.security.app-sandbox`.**
- **In-app updater (`AppUpdater`)** spawns `brew upgrade` via `Process()` — **only works because there's no sandbox.**
- **Dependency:** WhisperKit (SPM, MIT) — bundled source.
- Bundle ID `com.oluyinka.MeetingIntro`; `LSUIElement` (menu-bar only). Apple Developer Program membership already in place (used for notarization).

> ⚠️ **Reality check:** the repo has been public the whole time. Going private protects only **future** code; anything already pushed is already visible and may be copied. "All rights reserved" still legally bars reuse, but enforcement is the only remedy for what's already out.

---

## TRACK A — Protect the source (no forks)

### A1. License stance
- **Do NOT adopt MIT/Apache** (those permit forking). Keep **proprietary / all-rights-reserved.**
- Optionally add a short **`LICENSE`** that is an explicit proprietary notice (e.g., "All rights reserved. No permission is granted to copy, modify, or redistribute." ) rather than an OSI license. This makes intent unambiguous.
- About line stays "All rights reserved" (do not switch to "MIT License").

### A2. Make the source private
- **Set `templegit9/MeetingIntro` to Private** (GitHub repo settings).
- **Conflict to resolve:** the Homebrew cask downloads the release `.zip` from a **public** URL. Private-repo release assets require auth → **`brew install/upgrade` would break.** Options:
  - **A2-opt-1 (recommended):** keep a **separate PUBLIC repo for release artifacts only** (no source) — e.g. `templegit9/meetingintro-dist` — and have `release.sh` create the GitHub Release + upload the `.zip` **there**. Point the cask `url` at that repo's release assets. Source stays in the private repo.
  - **A2-opt-2:** host the `.zip` on your **own server / CDN / S3** and point the cask there. More infra.
  - The tap (`templegit9/homebrew-tap`) is already public and contains no source — it stays as-is; only the artifact URL in the cask changes.
- **`release.sh` changes:** push the source to the private origin; create the Release/upload the asset to the public *dist* repo; compute SHA-256; update the cask URL+sha in the tap. (Mostly a change of which repo the `gh release create` targets.)

### A3. Cosmetic
- Decide the **copyright name** (real name vs "TempleGit"). App Store requires a real legal entity/person name for the seller anyway (see B6).

### A4. Track A risks
| Risk | Mitigation |
|---|---|
| Private repo breaks the public cask download | Host artifacts in a public dist repo / CDN (A2); re-point cask URL. |
| Past public source already copied | Accept; "all rights reserved" is the legal backstop. Consider whether it matters given the app is free. |
| Notarized Developer-ID builds are still decompilable (no DRM) | True for any direct-download Mac app. App Store (Track B) adds FairPlay DRM if protection matters more. |
| `release.sh` complexity grows (two repos) | Keep one script; parameterize the dist repo. Test a dry-run release. |

---

## TRACK B — Mac App Store listing

### B1. The hard blocker: App Sandbox
- **App Store requires `com.apple.security.app-sandbox = true`.**
- The **in-app updater spawns `brew` via `Process()`** — **forbidden in the sandbox**, and the **Store handles updates itself**, so the brew updater is both impossible and unnecessary in an App Store build.
- **App Store guidelines also forbid referencing external distribution** (Homebrew, "brew upgrade", direct download) inside the app.
- → For the App Store build, **compile out** `AppUpdater`, the About "Check for updates" control, and any "brew upgrade" copy (e.g., behind a build flag like `APPSTORE`).

### B2. What survives the sandbox (add entitlements alongside `app-sandbox`)
- **Calendar:** `com.apple.security.personal-information.calendars` ✅ (+ `NSCalendarsUsageDescription`).
- **Microphone:** `com.apple.security.device.audio-input` ✅ (+ `NSMicrophoneUsageDescription`).
- **Screen Recording (ScreenCaptureKit for system audio):** works under sandbox with user permission (+ `NSScreenCaptureUsageDescription`). Verify capture still functions in a sandboxed build.
- **User-picked save folder:** `com.apple.security.files.user-selected.read-write` ✅ (already using security-scoped bookmarks).
- **Network (Graph OAuth, GitHub release-notes/What's New):** `com.apple.security.network.client` ✅.
- **Launch at login:** use `SMAppService` (sandbox-compatible).

### B3. What must change / verify under sandbox
- **Remove the brew self-updater** (B1).
- **Shortcuts invocation** (`shortcuts://run-shortcut`) via `NSWorkspace.open` — verify it works sandboxed (URL open is generally allowed); if not, the Focus handoff feature may need adjustment or a graceful "unavailable on App Store build" note.
- **Calendar mirror / Quick Add writes** — EventKit writes are fine sandboxed.
- **"What's New" tab** fetches GitHub Releases — fine (network), but consider whether to keep it (Store shows release notes natively).
- **Diagnostics file writes** to Application Support — fine (sandbox container).

### B4. Build configuration
- Add an **App Store target/config** (or an `xcconfig`/build setting) that:
  - sets `ENABLE_APP_SANDBOX`/adds the `app-sandbox` entitlement,
  - uses **App Store provisioning** (not Developer ID),
  - **does not** set `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO` the same way (App Store signing differs),
  - defines `APPSTORE` to compile out the updater + external-distribution references.
- Keep the existing Developer-ID/Homebrew config for the direct build (if doing both channels).
- Generated via `project.yml` — add a second configuration/target there (never hand-edit the pbxproj).

### B5. App Review prep
- **Privacy policy URL** (required). Must cover: calendar data (local + Microsoft Graph), microphone + screen recording for meeting recording, on-device vs. cloud transcription (WhisperKit local vs. Groq cloud — disclose the cloud upload to Groq), any analytics (none currently).
- **Usage description strings** for calendar/mic/screen-recording (have most; verify wording is reviewer-friendly).
- **Recording disclaimer** already exists (`hasAcceptedDisclaimer`) — good for Review.
- **Data collection disclosures** (App Privacy "nutrition label"): calendar data, audio. Note the **Groq transcription** sends audio to a third party — must be disclosed; consider making cloud transcription opt-in/clearly labeled.
- **No external-distribution mentions** in the Store build (B1).
- **Demo/credentials for reviewers** if Microsoft 365 login is needed to test (provide a test account or make EventKit the default path for review).

### B6. Store logistics
- Seller name (legal person/entity) shown on the listing.
- App name availability ("MeetingIntro"), category, screenshots, description, keywords, icon (1024px).
- **Pricing model** — decide (free / paid up-front / freemium + IAP). Affects whether to add StoreKit.

### B7. Track B risks
| Risk | Mitigation |
|---|---|
| Sandbox breaks the brew self-updater | Compile it out for the App Store build; Store auto-updates. |
| Sandbox silently disables a capability (recording/Shortcuts) | Build a sandboxed Debug build EARLY and test each feature before investing in Review. |
| App Review rejects over recording/privacy | Privacy policy + clear disclosures + opt-in cloud transcription; disclaimer already present. |
| Store rule: no mention of Homebrew/external distribution | `APPSTORE` flag strips updater + copy. |
| Entitlement drift between the two builds | We've shipped entitlement bugs before — keep both entitlement files in `project.yml`, diff them, and verify the signed bundle's entitlements per release. |
| Maintaining two build configs ongoing | Accept as the cost of dual-channel; or go App-Store-only to simplify (see §7 Q1). |
| WhisperKit (and any SPM dep) license compliance | MIT — include its notice in an acknowledgements section regardless of channel. |

---

## 7. Open decisions (resolve before executing)

1. **Both channels, or App Store only?**
   - *App Store only* → simplest: one sandboxed build, delete the brew updater + Homebrew cask + release.sh complexity entirely. Lose power-user/instant-install audience.
   - *Both* → keep Developer-ID/Homebrew (not sandboxed, with updater) **and** a sandboxed App Store build. Two configs to maintain.
2. **Free or paid** on the App Store? (Drives whether to add StoreKit/IAP.)
3. **License text:** keep implicit "all rights reserved", or add an explicit proprietary `LICENSE` file?
4. **Copyright/seller name:** "TempleGit" vs. a legal name.
5. **Make the source repo private now** (Track A), independent of the App Store timeline?

## 8. Suggested sequencing

- **Phase 1 (small, immediate) — Track A protection:** add proprietary `LICENSE`, set repo private, stand up a public *dist* repo (or CDN), re-point the cask URL in `release.sh` + tap, dry-run a release to confirm `brew upgrade` still works.
- **Phase 2 — App Store spike:** add the sandboxed build config + `APPSTORE` flag (compile out updater), produce a sandboxed Debug build, and **manually verify every capability** (calendar, mic, screen-record, Graph, Shortcuts, mirror, recording→notes). This de-risks B before any Review effort.
- **Phase 3 — Store submission:** privacy policy, App Privacy labels, screenshots/metadata, pricing/StoreKit if paid, submit to Review; iterate on rejections.
- **Phase 4 — ongoing:** dual-release runbook (if both channels), entitlement-diff check in the release checklist.

## 9. Effort / reality

- Track A: ~half a day (repo private + artifact-hosting split + cask re-point + dry run).
- Track B: multi-day + **App Review latency (days, with iteration)**. The sandbox capability spike (Phase 2) is the make-or-break; do it before committing to the Store.
