#!/bin/bash
# Runs the unit tests.
# - The build folder lives in $TMPDIR: under iCloud Drive (~/Documents) files get touched and
#   tagged with extended attributes during the build, which breaks it.
# - With only the Command Line Tools installed, the Swift Testing framework is outside the
#   default search path, so it is added explicitly. With Xcode nothing extra is needed.
set -euo pipefail
cd "$(dirname "$0")/.."
SCRATCH="${TMPDIR:-/tmp}/OpenSubtitlesUploader-build"
find Sources Tests -name "* 2.*" -delete 2>/dev/null || true
if [[ "$(xcode-select -p 2>/dev/null)" == *CommandLineTools* ]]; then
    FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
    exec swift test --scratch-path "$SCRATCH" --build-system native -Xswiftc -F"$FW" -Xlinker -F"$FW" "$@"
else
    exec swift test --scratch-path "$SCRATCH" "$@"
fi
