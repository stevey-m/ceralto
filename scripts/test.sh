#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
TOOLCHAIN_BIN="$(dirname "$(xcrun --find swiftc)")"
TESTING_PLUGIN="$TOOLCHAIN_BIN/../lib/swift/host/plugins/testing/libTestingMacros.dylib"

# Some Command Line Tools releases do not discover their bundled testing plugin.
# Native window tests share NSApplication and AppKit appearance state.
if [[ -f "$TESTING_PLUGIN" ]]; then
    swift test --no-parallel -Xswiftc -load-plugin-library -Xswiftc "$TESTING_PLUGIN" "$@"
else
    swift test --no-parallel "$@"
fi
