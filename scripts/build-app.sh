#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
SDK_VERSION="$(xcrun --show-sdk-version)"
MINIMUM_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Support/Info.plist)"
# Swift Build can otherwise stamp the deployment target as the SDK version.
swift build --configuration release \
    -Xlinker -platform_version -Xlinker macos -Xlinker "$MINIMUM_OS" -Xlinker "$SDK_VERSION"
BIN_DIR="$(swift build --configuration release --show-bin-path)"
APP="$PWD/dist/Ceralto.app"
mkdir -p "$PWD/dist"
STAGING="$(mktemp -d "$PWD/dist/app-staging.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
BUNDLE="$STAGING/Ceralto.app"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN_DIR/Folio" "$BUNDLE/Contents/MacOS/Ceralto"
BUILT_SDK="$(xcrun vtool -show-build "$BUNDLE/Contents/MacOS/Ceralto" | awk '$1 == "sdk" { print $2 }')"
if [[ "$BUILT_SDK" != "$SDK_VERSION" ]]; then
    printf 'Incorrect executable SDK stamp: expected %s, got %s\n' "$SDK_VERSION" "$BUILT_SDK" >&2
    exit 1
fi
cp Support/Info.plist "$BUNDLE/Contents/Info.plist"
install -m 644 .build/checkouts/Yams/LICENSE "$BUNDLE/Contents/Resources/Yams-LICENSE.txt"
install -m 644 .build/checkouts/SwiftSoup/LICENSE "$BUNDLE/Contents/Resources/SwiftSoup-LICENSE.txt"
install -m 644 .build/checkouts/swift-cmark/COPYING "$BUNDLE/Contents/Resources/cmark-COPYING.txt"
install -m 644 LICENSE "$BUNDLE/Contents/Resources/Folio-LICENSE.txt"
swift scripts/make-icon.swift "$PWD/dist/Folio.iconset"
iconutil -c icns "$PWD/dist/Folio.iconset" -o "$BUNDLE/Contents/Resources/Folio.icns"
codesign --force --sign - "$BUNDLE"
codesign --verify --deep --strict "$BUNDLE"
if [[ -e "$APP" ]]; then mv "$APP" "$STAGING/Previous.app"; fi
if ! mv "$BUNDLE" "$APP"; then
    if [[ -e "$STAGING/Previous.app" ]]; then mv "$STAGING/Previous.app" "$APP"; fi
    exit 1
fi
printf '\nBuilt %s\nLaunch with: open "%s"\n' "$APP" "$APP"
