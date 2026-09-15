#!/usr/bin/env bash
# Build, sign and upload the Mac App Store build.
#
# The Homebrew pipeline (scripts/release.sh) is untouched and still ships the Developer ID
# build. This is its sibling for the sandboxed App Store target.
#
# Credentials, in order of preference:
#   1. App Store Connect API key — set ASC_KEY_ID and ASC_ISSUER_ID; the .p8 is read from
#      ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8
#   2. Apple ID + app-specific password — falls back to APPLE_ID / APPLE_APP_PASSWORD
#      from .env.release, the same pair notarization already uses.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
# .env.release is gitignored, so it exists in the primary checkout but NOT in a git
# worktree — where this script is most likely to be run, since App Store work is kept on
# its own branch. Fall back to the main checkout's copy, then to ~/.meetingintro.env,
# rather than building for ten minutes and only then discovering there are no credentials.
for env_file in \
  "$REPO_ROOT/.env.release" \
  "$(git -C "$REPO_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's|/\.git$||')/.env.release" \
  "$HOME/.meetingintro.env"
do
  [ -f "$env_file" ] && { set -a; source "$env_file"; set +a; break; }
done

# Fail on missing credentials NOW, not after the archive.
if [ -z "${ASC_KEY_ID:-}" ] || [ -z "${ASC_ISSUER_ID:-}" ]; then
  if [ -z "${APPLE_ID:-}" ] || [ -z "${APPLE_APP_PASSWORD:-}" ]; then
    echo "✗ No upload credentials found."
    echo "  Set ASC_KEY_ID + ASC_ISSUER_ID (preferred; .p8 in ~/.appstoreconnect/private_keys/),"
    echo "  or APPLE_ID + APPLE_APP_PASSWORD, in .env.release or ~/.meetingintro.env."
    exit 1
  fi
fi

VERSION="${1:-}"
[ -z "$VERSION" ] && { echo "usage: $0 <version>   e.g. $0 2.20.6"; exit 1; }

BUILD_DIR="$REPO_ROOT/build/appstore"
ARCHIVE="$BUILD_DIR/MeetingIntro.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
TEAM_ID="${MEETINGINTRO_TEAM_ID:-PVRL9W627Q}"

echo "▶ Regenerating project"
command -v xcodegen >/dev/null && xcodegen generate >/dev/null

echo "▶ Bumping MARKETING_VERSION to $VERSION"
/usr/bin/sed -i '' "s|MARKETING_VERSION: \".*\"|MARKETING_VERSION: \"$VERSION\"|g" project.yml
command -v xcodegen >/dev/null && xcodegen generate >/dev/null

# App Store Connect rejects a build whose CFBundleVersion it has seen before, even for a
# rejected submission — so the build number is a timestamp, never a hand-typed integer.
BUILD_NUMBER="$(date +%Y%m%d%H%M)"

# Signing deliberately uses the Xcode account rather than the API key. An App Manager key
# cannot create certificates or profiles — passing it makes xcodebuild fail with "Cloud
# signing permission error" instead of falling back to the account that can. The key is
# still used for the upload below, which is all it is needed for.
echo "▶ Signing via the signed-in Xcode account"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "▶ Archiving the sandboxed target"
xcodebuild -project MeetingIntro.xcodeproj \
  -scheme MeetingIntroMAS \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  -allowProvisioningUpdates \
  archive

cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <!-- "app-store" is deprecated in Xcode 26; the current name is app-store-connect. -->
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>destination</key><string>export</string>
  <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
PLIST

echo "▶ Exporting a .pkg for the store"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
  -allowProvisioningUpdates

PKG="$(find "$EXPORT_DIR" -name "*.pkg" | head -1)"
[ -z "$PKG" ] && { echo "✗ No .pkg produced — export failed"; exit 1; }
echo "▶ Built $PKG ($(du -h "$PKG" | cut -f1)), build number $BUILD_NUMBER"

# Validate BEFORE uploading. A rejected upload burns the build number and the round trip;
# validation catches entitlement and Info.plist problems in seconds.
if [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ]; then
  CREDS=(--apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID")
else
  CREDS=(-u "${APPLE_ID:?APPLE_ID not set}" -p "${APPLE_APP_PASSWORD:?APPLE_APP_PASSWORD not set}")
fi

echo "▶ Validating with App Store Connect"
xcrun altool --validate-app -f "$PKG" -t macos "${CREDS[@]}"

echo "▶ Uploading"
xcrun altool --upload-app -f "$PKG" -t macos "${CREDS[@]}"

echo "✅ Uploaded $VERSION ($BUILD_NUMBER). It appears in App Store Connect → TestFlight/Builds after processing."
