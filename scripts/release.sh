#!/usr/bin/env bash
# scripts/release.sh — cut a notarized, Homebrew-installable release of MeetingIntro.
#
# What it does, in order:
#   1. Regenerates the Xcode project from project.yml
#   2. Builds the Release configuration into build/Release/MeetingIntro.app
#   3. Signs with Developer ID, enables hardened runtime
#   4. Zips and submits to Apple for notarization, then staples the ticket
#   5. Computes SHA-256, creates a GitHub release with the zip attached
#   6. Updates Casks/meetingintro.rb in templegit9/homebrew-tap and pushes
#
# Required environment (load from .env.release; see RELEASING.md):
#   MEETINGINTRO_SIGN_IDENTITY   e.g. "Developer ID Application: Your Name (TEAMID)"
#   MEETINGINTRO_TEAM_ID         your 10-char Apple Team ID
#   APPLE_ID                     Apple ID email used for notarization
#   APPLE_APP_PASSWORD           app-specific password (appleid.apple.com → Sign-In and Security)
#   TAP_REPO_PATH                local path to a clone of templegit9/homebrew-tap
#
# Required tools: xcodegen, xcodebuild, codesign, ditto, xcrun notarytool, gh, shasum.
#
# Usage:
#   scripts/release.sh 1.0.0

set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "Usage: $0 <version>   (e.g. $0 1.0.0)" >&2
  exit 1
fi

# Load secrets if .env.release exists (gitignored).
if [[ -f .env.release ]]; then
  set -a; source .env.release; set +a
fi

: "${MEETINGINTRO_SIGN_IDENTITY:?set in .env.release}"
: "${MEETINGINTRO_TEAM_ID:?set in .env.release}"
: "${APPLE_ID:?set in .env.release}"
: "${APPLE_APP_PASSWORD:?set in .env.release}"
: "${TAP_REPO_PATH:?set in .env.release}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build/release"
APP_PATH="$BUILD_DIR/Build/Products/Release/MeetingIntro.app"
ZIP_NAME="MeetingIntro-${VERSION}.zip"
ZIP_PATH="$REPO_ROOT/build/$ZIP_NAME"

echo "▶ Bumping project.yml MARKETING_VERSION to $VERSION"
/usr/bin/sed -i '' "s|MARKETING_VERSION: \".*\"|MARKETING_VERSION: \"$VERSION\"|" "$REPO_ROOT/project.yml"
( cd "$REPO_ROOT" && \
    git add project.yml && \
    if ! git diff --cached --quiet; then \
        git commit -m "chore: bump version to $VERSION" && \
        git push origin main; \
    fi )

echo "▶ Regenerating Xcode project"
( cd "$REPO_ROOT" && xcodegen generate )

echo "▶ Building Release"
rm -rf "$BUILD_DIR"
xcodebuild \
  -project "$REPO_ROOT/MeetingIntro.xcodeproj" \
  -scheme MeetingIntro \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$(date +%Y%m%d%H%M)" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$MEETINGINTRO_SIGN_IDENTITY" \
  DEVELOPMENT_TEAM="$MEETINGINTRO_TEAM_ID" \
  ENABLE_HARDENED_RUNTIME=YES \
  build

[[ -d "$APP_PATH" ]] || { echo "✗ Build did not produce $APP_PATH" >&2; exit 1; }

echo "▶ Verifying code signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "▶ Zipping app for notarization"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "▶ Submitting to Apple notary service (this can take a few minutes)"
NOTARY_OUT="$(xcrun notarytool submit "$ZIP_PATH" \
  --apple-id "$APPLE_ID" \
  --team-id "$MEETINGINTRO_TEAM_ID" \
  --password "$APPLE_APP_PASSWORD" \
  --wait 2>&1)"
echo "$NOTARY_OUT"

if ! echo "$NOTARY_OUT" | grep -qE "status: Accepted"; then
  SUBMISSION_ID="$(echo "$NOTARY_OUT" | awk '/id: [a-f0-9-]{36}/ {print $2; exit}')"
  echo "✗ Notarization did not succeed. Fetching detailed log:" >&2
  xcrun notarytool log "$SUBMISSION_ID" \
    --apple-id "$APPLE_ID" \
    --team-id "$MEETINGINTRO_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" >&2 || true
  exit 1
fi

echo "▶ Stapling ticket to .app"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

echo "▶ Re-zipping stapled app"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

SHA256="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
echo "▶ Artifact SHA-256: $SHA256"

echo "▶ Creating GitHub release v$VERSION"
TAG="v$VERSION"

# Build a "What's changed" section from commits since the previous tag. We bound
# the list at 30 entries so a long gap between releases doesn't produce wall-of-
# text release notes.
PREV_TAG="$(cd "$REPO_ROOT" && git describe --tags --abbrev=0 HEAD^ 2>/dev/null || echo '')"
if [[ -n "$PREV_TAG" ]]; then
    CHANGELOG_LINES="$(cd "$REPO_ROOT" && git log "$PREV_TAG..HEAD" --pretty=format:'- %s' -- MeetingIntro/ project.yml scripts/ Casks/ CLAUDE.md RELEASING.md 2>/dev/null | head -n 30)"
    if [[ -z "$CHANGELOG_LINES" ]]; then
        CHANGELOG_LINES="- (no user-facing changes since $PREV_TAG)"
    fi
    CHANGELOG_HEADER="## What's changed since $PREV_TAG"
else
    CHANGELOG_LINES="- Initial release"
    CHANGELOG_HEADER="## What's in this release"
fi

RELEASE_NOTES="$CHANGELOG_HEADER

$CHANGELOG_LINES

## Install

### If you already have Homebrew

\`\`\`sh
brew install --cask templegit9/tap/meetingintro
\`\`\`

### If you don't have Homebrew yet

Install Homebrew first (one-time, takes a minute):

\`\`\`sh
/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"
\`\`\`

Then install MeetingIntro:

\`\`\`sh
brew install --cask templegit9/tap/meetingintro
\`\`\`

### Updating to the latest version

\`\`\`sh
brew upgrade --cask templegit9/tap/meetingintro
\`\`\`

The app is signed with Developer ID and notarized by Apple, so it opens without Gatekeeper warnings."
( cd "$REPO_ROOT" && \
    git tag -a "$TAG" -m "Release $TAG" 2>/dev/null || true ; \
    git push origin "$TAG" 2>/dev/null || true ; \
    gh release create "$TAG" "$ZIP_PATH" \
      --title "MeetingIntro $VERSION" \
      --notes "$RELEASE_NOTES" \
      || gh release upload "$TAG" "$ZIP_PATH" --clobber )

echo "▶ Updating cask in $TAP_REPO_PATH"
CASK_FILE="$TAP_REPO_PATH/Casks/meetingintro.rb"
mkdir -p "$(dirname "$CASK_FILE")"
cp "$REPO_ROOT/Casks/meetingintro.rb" "$CASK_FILE"
# Substitute version + sha into the tap copy.
/usr/bin/sed -i '' \
  -e "s|version \"0.0.0\"|version \"$VERSION\"|" \
  -e "s|sha256 \"0000000000000000000000000000000000000000000000000000000000000000\"|sha256 \"$SHA256\"|" \
  "$CASK_FILE"

( cd "$TAP_REPO_PATH" && \
    git add Casks/meetingintro.rb && \
    git commit -m "meetingintro $VERSION" && \
    git push )

echo "✅ Done. Test with: brew install --cask templegit9/tap/meetingintro"
