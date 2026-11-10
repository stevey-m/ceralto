#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
swift scripts/make-icon.swift "$PWD/Mobile/Assets.xcassets/AppIcon.appiconset" --ios
xcodebuild -project FolioMobile.xcodeproj -scheme FolioMobile \
    -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath "$PWD/dist/IOSDevice" CODE_SIGNING_ALLOWED=NO build
printf '\nBuilt an unsigned iPhone/iPad app, not an installable release.\n'
printf 'Open FolioMobile.xcodeproj, choose your Personal Team and connected iPad, then Run.\n'
