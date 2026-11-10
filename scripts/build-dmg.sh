#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
bash scripts/build-app.sh

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/Deltos.app/Contents/Info.plist)"
ARCH="$(uname -m)"
DMG="$PWD/dist/Deltos-$VERSION-$ARCH.dmg"
STAGING="$(mktemp -d "$PWD/dist/dmg-staging.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT

ditto dist/Deltos.app "$STAGING/Deltos.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Deltos" -srcfolder "$STAGING" -format UDZO -ov "$DMG"
hdiutil verify "$DMG"
printf '\nInstaller: %s\nOpen it and drag Deltos into Applications.\n' "$DMG"
