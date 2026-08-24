#!/bin/bash
# Runs the DisplayVolume unit tests.
#
# With full Xcode installed, `swift test` works directly.
# With only the Command Line Tools, the Swift Testing framework needs
# explicit search paths (CLT ships Testing.framework outside the default
# lookup locations); this script adds them automatically when required.

set -euo pipefail
cd "$(dirname "$0")/.."

if xcode-select -p 2>/dev/null | grep -qv CommandLineTools; then
    exec swift test "$@"
fi

FWK=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
LIB=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
exec swift test \
    -Xswiftc -F"$FWK" \
    -Xlinker -F"$FWK" \
    -Xlinker -rpath -Xlinker "$FWK" \
    -Xlinker -rpath -Xlinker "$LIB" \
    "$@"
