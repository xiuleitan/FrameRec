#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
swift build -c debug --product FrameRecSelectionProbe
BINARY_DIR="$(swift build -c debug --show-bin-path)"
APP_DIR="$PROJECT_DIR/build/FrameRecSelectionProbe.app"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$BINARY_DIR/FrameRecSelectionProbe" "$APP_DIR/Contents/MacOS/FrameRecSelectionProbe"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>FrameRecSelectionProbe</string>
<key>CFBundleIdentifier</key><string>com.framerec.selectionprobe</string>
<key>CFBundleName</key><string>FrameRecSelectionProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP_DIR"
print "Built: $APP_DIR"
