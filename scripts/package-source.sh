#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)
mkdir -p dist
ARCHIVE="$PWD/dist/Ceralto-$VERSION-source.tar.gz"
tar -czf "$ARCHIVE" \
    --exclude='.DS_Store' --exclude='xcuserdata' --exclude='*.xcuserstate' \
    Package.swift Package.resolved Sources Tests Support scripts Mobile \
    FolioMobile.xcodeproj README.md LICENSE CONTRIBUTING.md EXTENSIONS.md Examples docs .gitignore .github
echo "Standalone MIT-licensed source: $ARCHIVE"
