#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
"$PROJECT_DIR/scripts/build.sh" "${1:-debug}"
open "$PROJECT_DIR/build/FrameRec.app"
