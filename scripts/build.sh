#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
CONFIGURATION="${1:-release}"
ARCHITECTURE="${2:-native}"
if (( $# > 2 )) || [[ "$CONFIGURATION" != "release" && "$CONFIGURATION" != "debug" ]] || \
   [[ "$ARCHITECTURE" != "native" && "$ARCHITECTURE" != "universal" ]]; then
    print -u2 "Usage: ./scripts/build.sh [release|debug] [native|universal]"
    exit 1
fi
BUILD_ARGUMENTS=(-c "$CONFIGURATION")
APP_PARENT="$PROJECT_DIR/build"
if [[ "$ARCHITECTURE" == "universal" ]]; then
    BUILD_ARGUMENTS+=(--arch arm64 --arch x86_64 --scratch-path "$PROJECT_DIR/.build/release-universal")
    APP_PARENT="$PROJECT_DIR/build/universal"
fi
swift build "${BUILD_ARGUMENTS[@]}" --product FrameRec
BINARY_DIR="$(swift build "${BUILD_ARGUMENTS[@]}" --show-bin-path)"
APP_DIR="$APP_PARENT/FrameRec.app"
mkdir -p "$APP_PARENT"
PACKAGE_STAGE="$(mktemp -d "$APP_PARENT/.package.XXXXXXXX")"
trap 'rm -rf "$PACKAGE_STAGE"' EXIT
STAGED_APP_DIR="$PACKAGE_STAGE/FrameRec.app"
mkdir -p "$STAGED_APP_DIR/Contents/MacOS" "$STAGED_APP_DIR/Contents/Resources"
cp "$BINARY_DIR/FrameRec" "$STAGED_APP_DIR/Contents/MacOS/FrameRec"
if [[ "$CONFIGURATION" == "release" ]]; then
    strip -S -x "$STAGED_APP_DIR/Contents/MacOS/FrameRec"
fi
if [[ "$ARCHITECTURE" == "universal" ]]; then
    for REQUIRED_ARCHITECTURE in arm64 x86_64; do
        lipo "$STAGED_APP_DIR/Contents/MacOS/FrameRec" -verify_arch "$REQUIRED_ARCHITECTURE"
    done
fi
cp "$PROJECT_DIR/Resources/Info.plist" "$STAGED_APP_DIR/Contents/Info.plist"
ICON_CACHE="$PROJECT_DIR/build/AppIcon.icns"
if [[ ! -f "$ICON_CACHE" || "$PROJECT_DIR/scripts/make-icon.swift" -nt "$ICON_CACHE" ]]; then
    swift "$PROJECT_DIR/scripts/make-icon.swift" "$PROJECT_DIR/build"
    iconutil -c icns "$PROJECT_DIR/build/AppIcon.iconset" -o "$ICON_CACHE"
fi
cp "$ICON_CACHE" "$STAGED_APP_DIR/Contents/Resources/AppIcon.icns"
python3 "$PROJECT_DIR/scripts/sign-app.py" "$STAGED_APP_DIR"
# Replace the bundle instead of overwriting the executable of a running app.
# Its existing process can continue using the old inode until the user restarts.
if [[ -d "$APP_DIR" ]]; then
    mv "$APP_DIR" "$PACKAGE_STAGE/previous.app"
fi
if ! mv "$STAGED_APP_DIR" "$APP_DIR"; then
    if [[ -d "$PACKAGE_STAGE/previous.app" ]]; then
        mv "$PACKAGE_STAGE/previous.app" "$APP_DIR"
    fi
    exit 1
fi
print "Built: $APP_DIR"
