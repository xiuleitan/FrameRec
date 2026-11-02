#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
if (( $# != 0 )); then
    print -u2 "Usage: ./scripts/package-release.sh"
    exit 1
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
ASSET_NAME="FrameRec-${VERSION}-macOS-universal"
OUTPUT_DIR="$PROJECT_DIR/build/releases/v${VERSION}"
if [[ -e "$OUTPUT_DIR" ]]; then
    print -u2 "Release output already exists: $OUTPUT_DIR. Move it aside before rebuilding."
    exit 1
fi
"$PROJECT_DIR/scripts/build.sh" release universal
APP_DIR="$PROJECT_DIR/build/universal/FrameRec.app"
RELEASE_STAGE="$(mktemp -d "$PROJECT_DIR/build/.release.XXXXXXXX")"
trap 'rm -rf "$RELEASE_STAGE"' EXIT
mkdir -p "$RELEASE_STAGE/image" "$RELEASE_STAGE/assets" "$RELEASE_STAGE/zip-check"
ditto --norsrc --noextattr --noacl "$APP_DIR" "$RELEASE_STAGE/image/FrameRec.app"
ln -s /Applications "$RELEASE_STAGE/image/Applications"
cp docs/INSTALL.zh-CN.txt docs/INSTALL.en.txt LICENSE "$RELEASE_STAGE/image/"
codesign --verify --deep --strict --all-architectures "$RELEASE_STAGE/image/FrameRec.app"
ditto -c -k --keepParent --norsrc --noextattr --noacl \
    "$RELEASE_STAGE/image/FrameRec.app" "$RELEASE_STAGE/assets/${ASSET_NAME}.zip"
hdiutil create -volname "FrameRec ${VERSION}" -srcfolder "$RELEASE_STAGE/image" \
    -fs HFS+ -format UDZO "$RELEASE_STAGE/assets/${ASSET_NAME}.dmg"
hdiutil verify "$RELEASE_STAGE/assets/${ASSET_NAME}.dmg"
ditto -x -k "$RELEASE_STAGE/assets/${ASSET_NAME}.zip" "$RELEASE_STAGE/zip-check"
codesign --verify --deep --strict --all-architectures "$RELEASE_STAGE/zip-check/FrameRec.app"
for REQUIRED_ARCHITECTURE in arm64 x86_64; do
    lipo "$RELEASE_STAGE/zip-check/FrameRec.app/Contents/MacOS/FrameRec" -verify_arch "$REQUIRED_ARCHITECTURE"
done
python3 - "$RELEASE_STAGE/assets" "$RELEASE_STAGE/zip-check/FrameRec.app" <<'PY'
import hashlib
from pathlib import Path
import sys

assets, application = map(Path, sys.argv[1:])
for path in application.rglob('*'):
    if not path.is_file():
        continue
    if path.suffix.lower() in {'.key', '.pem', '.p12', '.pfx', '.keychain-db'} or path.name in {'password', 'identity.json', '.DS_Store'}:
        raise SystemExit(f'Unexpected private or local file in app: {path.name}')
    data = path.read_bytes()
    if b'-----BEGIN PRIVATE KEY-----' in data or b'/Users/' in data or b'/home/' in data:
        raise SystemExit(f'Private material or local user path found in app: {path.name}')
lines = [f'{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n'
         for path in sorted(assets.iterdir()) if path.suffix in {'.dmg', '.zip'}]
(assets / 'SHA256SUMS.txt').write_text(''.join(lines))
print('Both architectures, archive signatures, and app privacy checks passed.')
PY
mkdir -p "$PROJECT_DIR/build/releases"
mv "$RELEASE_STAGE/assets" "$OUTPUT_DIR"
print "Release assets: $OUTPUT_DIR"
