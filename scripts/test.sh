#!/bin/bash
# Run the test suite.
#
# With only the Command Line Tools installed, swift-testing lives outside the
# default search paths, so `swift test` alone fails with "no such module
# 'Testing'". The CLT copy of the Testing+Foundation cross-import overlay is
# also incomplete (no Modules), hence -disable-cross-import-overlays.
# Xcode users don't need the extra flags, but they don't hurt.

set -euo pipefail
cd "$(dirname "$0")/.."

FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
extra=()
if [ -d "$FW/Testing.framework" ]; then
  extra=(-Xswiftc -F -Xswiftc "$FW"
         -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays
         -Xlinker -rpath -Xlinker "$FW")
fi

swift test "${extra[@]}" "$@"
