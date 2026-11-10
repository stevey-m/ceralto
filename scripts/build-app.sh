#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
swift build --configuration release
BIN_DIR="$(swift build --configuration release --show-bin-path)"
APP="$PWD/dist/Folio.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Folio" "$APP/Contents/MacOS/Folio"
cp Support/Info.plist "$APP/Contents/Info.plist"
install -m 644 .build/checkouts/Yams/LICENSE "$APP/Contents/Resources/Yams-LICENSE.txt"
install -m 644 .build/checkouts/SwiftSoup/LICENSE "$APP/Contents/Resources/SwiftSoup-LICENSE.txt"
install -m 644 .build/checkouts/swift-cmark/COPYING "$APP/Contents/Resources/cmark-COPYING.txt"
install -m 644 LICENSE "$APP/Contents/Resources/Folio-LICENSE.txt"
swift scripts/make-icon.swift "$PWD/dist/Folio.iconset"
iconutil -c icns "$PWD/dist/Folio.iconset" -o "$APP/Contents/Resources/Folio.icns"
codesign --force --sign - "$APP"
printf '\nBuilt %s\nLaunch with: open "%s"\n' "$APP" "$APP"
