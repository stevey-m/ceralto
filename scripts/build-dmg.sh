#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)"
ARCH="$(uname -m)"
DMG="$PWD/dist/Deltos-$VERSION-$ARCH.dmg"
ZIP="$PWD/dist/Deltos-$VERSION-$ARCH.zip"
if [[ -e "$DMG" || -e "$ZIP" ]]; then
    printf 'Refusing to overwrite an existing installer for Deltos %s\n' "$VERSION" >&2
    exit 1
fi
bash scripts/build-app.sh

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/Deltos.app/Contents/Info.plist)"
ARCH="$(uname -m)"
DMG="$PWD/dist/Deltos-$VERSION-$ARCH.dmg"
STAGING="$(mktemp -d "$PWD/dist/dmg-staging.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT

ditto dist/Deltos.app "$STAGING/Deltos $VERSION.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Deltos" -srcfolder "$STAGING" -format UDZO "$DMG"
hdiutil verify "$DMG"
ditto -c -k --sequesterRsrc --keepParent "$STAGING/Deltos $VERSION.app" "$ZIP"
printf '\nInstaller: %s\nOpen it and drag Deltos into Applications.\n' "$DMG"
printf 'Alternate ZIP: %s\n' "$ZIP"
