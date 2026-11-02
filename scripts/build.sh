#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
CONFIGURATION="${1:-release}"
if [[ "$CONFIGURATION" != "release" && "$CONFIGURATION" != "debug" ]]; then
    print -u2 "Usage: ./scripts/build.sh [release|debug]"
    exit 1
fi
swift build -c "$CONFIGURATION" --product FrameRec
BINARY_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"
APP_DIR="$PROJECT_DIR/build/FrameRec.app"
mkdir -p "$PROJECT_DIR/build"
PACKAGE_STAGE="$(mktemp -d "$PROJECT_DIR/build/.package.XXXXXXXX")"
trap 'rm -rf "$PACKAGE_STAGE"' EXIT
STAGED_APP_DIR="$PACKAGE_STAGE/FrameRec.app"
mkdir -p "$STAGED_APP_DIR/Contents/MacOS" "$STAGED_APP_DIR/Contents/Resources"
cp "$BINARY_DIR/FrameRec" "$STAGED_APP_DIR/Contents/MacOS/FrameRec"
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
