#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
ARCH="$(uname -m)"
TRIPLE="$ARCH-apple-ios17.0-simulator"
SCRATCH="$PWD/dist/IOSCore"

# This compile-only check also works when CoreSimulator has not been installed.
swift build --build-system native --target NotesCore --triple "$TRIPLE" --sdk "$SDK" --scratch-path "$SCRATCH"
BIN_DIR="$(swift build --build-system native --triple "$TRIPLE" --sdk "$SDK" --scratch-path "$SCRATCH" --show-bin-path)"
CHECKOUTS="$SCRATCH/checkouts"
xcrun swiftc -typecheck -parse-as-library -swift-version 6 -target "$TRIPLE" -sdk "$SDK" \
    -I "$BIN_DIR/Modules" \
    -Xcc "-fmodule-map-file=$CHECKOUTS/Yams/Sources/CYaml/include/module.modulemap" \
    -Xcc "-I$CHECKOUTS/Yams/Sources/CYaml/include" \
    -Xcc "-fmodule-map-file=$CHECKOUTS/swift-cmark/src/include/module.modulemap" \
    -Xcc "-I$CHECKOUTS/swift-cmark/src/include" \
    -Xcc "-fmodule-map-file=$CHECKOUTS/swift-cmark/extensions/include/module.modulemap" \
    -Xcc "-I$CHECKOUTS/swift-cmark/extensions/include" \
    Sources/Folio/NotesStore.swift Mobile/FolioMobileApp.swift
printf '\nShared models and native iPhone/iPad sources compiled for %s.\nThis is not an installed or runtime-tested mobile app.\n' "$TRIPLE"
