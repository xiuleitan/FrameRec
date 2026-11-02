#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
TOOL_DEVELOPER_DIR="$(xcode-select -p)"
TEST_FRAMEWORKS="$TOOL_DEVELOPER_DIR/Library/Developer/Frameworks"
TEST_PLUGIN="$TOOL_DEVELOPER_DIR/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [[ -d "$TEST_FRAMEWORKS/Testing.framework" && -f "$TEST_PLUGIN" ]]; then
    # CLT 27 places the testing runtime outside SwiftPM's default search paths.
    swift test --disable-xctest \
        -Xswiftc -F -Xswiftc "$TEST_FRAMEWORKS" \
        -Xswiftc -load-plugin-library -Xswiftc "$TEST_PLUGIN" \
        -Xlinker -F -Xlinker "$TEST_FRAMEWORKS" \
        -Xlinker -rpath -Xlinker "$TEST_FRAMEWORKS" "$@"
else
    swift test --disable-xctest "$@"
fi
