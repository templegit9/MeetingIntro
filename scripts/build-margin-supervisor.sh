#!/bin/sh
set -eu
output="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/MacOS/MarginRuntimeSupervisor"
mkdir -p "$(dirname "$output")"
# Build every architecture of the host app, including universal release archives.
set --
for architecture in $ARCHS; do
    set -- "$@" -arch "$architecture"
done
xcrun clang "$@" -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" -Os -Wall -Wextra -Werror "$SRCROOT/scripts/margin-runtime-supervisor.c" -o "$output"
/usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --options runtime "$output"
