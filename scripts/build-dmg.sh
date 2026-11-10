#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
bash scripts/build-app.sh

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/Folio.app/Contents/Info.plist)"
ARCH="$(uname -m)"
DMG="$PWD/dist/Folio-$VERSION-$ARCH.dmg"
STAGING="$(mktemp -d "$PWD/dist/dmg-staging.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT

ditto dist/Folio.app "$STAGING/Folio.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Folio" -srcfolder "$STAGING" -format UDZO -ov "$DMG"
hdiutil verify "$DMG"
printf '\nInstaller: %s\nOpen it and drag Folio into Applications.\n' "$DMG"
