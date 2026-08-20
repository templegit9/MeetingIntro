# Releasing MeetingIntro

End-state: users install with

```sh
brew install --cask templegit9/tap/meetingintro
```

To get there once, do the **one-time setup** below. After that, every release is `scripts/release.sh <version>`.

---

## One-time setup

### 1. Apple Developer account

Notarization is non-negotiable for a friction-free `brew install --cask` on modern macOS — without it, Gatekeeper quarantines the app on first launch.

1. Enroll at <https://developer.apple.com/programs/> ($99/year).
2. In Xcode → Settings → Accounts → your Apple ID → **Manage Certificates** → `+` → **Developer ID Application**. Xcode will install the cert + private key into your login keychain.
3. Verify:
   ```sh
   security find-identity -v -p codesigning
   ```
   You should see a line like `1) ABCD1234... "Developer ID Application: Your Name (TEAMID)"`. Copy that full quoted string — it's your `MEETINGINTRO_SIGN_IDENTITY`. The 10-char string in parens is your `MEETINGINTRO_TEAM_ID`.
4. Create an **app-specific password** at <https://account.apple.com/account/manage> → Sign-In and Security → App-Specific Passwords. This is `APPLE_APP_PASSWORD`. Your regular Apple ID password will not work for `notarytool`.

### 2. Install build tools

```sh
brew install xcodegen gh
```

`xcodebuild`, `codesign`, `ditto`, `xcrun`, `shasum` ship with Xcode/macOS.

### 3. Create the tap repo

A Homebrew tap is just a public GitHub repo named `homebrew-<anything>`. We use `homebrew-tap`:

1. Create an **empty public** repo at <https://github.com/new>: name `homebrew-tap`, owner `templegit9`.
2. Clone it locally:
   ```sh
   git clone https://github.com/templegit9/homebrew-tap.git ~/code/homebrew-tap
   mkdir -p ~/code/homebrew-tap/Casks
   ```
   The release script will write the cask file in there on each release. You don't need to populate it now.

### 4. Configure release secrets

Create `.env.release` at the repo root (already gitignored — see [.gitignore](./.gitignore)):

```sh
# .env.release
MEETINGINTRO_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
MEETINGINTRO_TEAM_ID="TEAMID"
APPLE_ID="you@example.com"
APPLE_APP_PASSWORD="abcd-efgh-ijkl-mnop"
TAP_REPO_PATH="/Users/oluyinkaoginni/code/homebrew-tap"
```

### 5. Authenticate `gh`

```sh
gh auth login          # pick GitHub.com, HTTPS, browser auth
```

---

## Cutting a release

```sh
scripts/release.sh 1.0.0
```

The script will, in order: regenerate the Xcode project, build Release, sign with your Developer ID, submit to Apple's notary service (this is the slow step — a few minutes), staple the ticket, zip the stapled `.app`, attach it to a new `v1.0.0` GitHub release, update `Casks/meetingintro.rb` in your tap repo with the new version + SHA-256, and push.

After it finishes, sanity-check on a clean Mac (or `brew uninstall --cask meetingintro && brew untap templegit9/tap` first):

```sh
brew install --cask templegit9/tap/meetingintro
open -a MeetingIntro
```

The app should open with no Gatekeeper warning. If you see "MeetingIntro can't be opened because Apple cannot check it for malicious software," notarization did not staple — re-run the script and watch the `notarytool submit --wait` output for the failure reason.

---

## Version bumps

`MARKETING_VERSION` is set via `xcodebuild` flag during the release build, so you do **not** need to edit `project.yml` to bump versions. The argument to `scripts/release.sh` is the source of truth.

`CURRENT_PROJECT_VERSION` (build number) is auto-set from the current timestamp, so it monotonically increases without manual bookkeeping.

---

## Release notes

Write the user-facing notes **with the feature commit**, in `docs/release-notes/<version>.md`. `scripts/release.sh` picks that file up automatically: it becomes the body of the GitHub release, with the auto-generated commit list preserved beneath it in a collapsed "All changes" section.

```sh
# notes are found automatically by version
scripts/release.sh 2.19.0

# or point at a file explicitly
scripts/release.sh 2.19.0 --notes /tmp/notes.md
```

If the file is missing the release still goes out, but the script warns and publishes raw commit subjects — which describe the change to a developer, not to a user. An explicit `--notes` path that doesn't exist fails immediately, before the build.

Write it for someone who has never seen the code: lead with the behaviour they get, and state plainly anything the feature deliberately does *not* do.

## Troubleshooting

- **`xcodebuild` fails with "No signing certificate"** — the Developer ID cert isn't in your login keychain, or `MEETINGINTRO_SIGN_IDENTITY` doesn't exactly match what `security find-identity` prints. The full quoted string including the parenthesized team ID must match.
- **`notarytool` returns `Invalid`** — run `xcrun notarytool log <submission-id> --apple-id ... --team-id ... --password ...` to see the per-issue log. Most common cause: a binary inside the bundle isn't hardened-runtime-signed. The `codesign --verify --deep --strict` step in the script will usually catch this earlier.
- **`brew install` fails with `SHA256 mismatch`** — the cask in the tap repo is out of sync with the artifact on Releases. Re-run `scripts/release.sh` with the same version (it overwrites the release with `gh release upload --clobber`).
- **Tap not found** — make sure the tap repo is public and the path in the install command matches: `templegit9/tap/meetingintro` resolves to `github.com/templegit9/homebrew-tap`.
