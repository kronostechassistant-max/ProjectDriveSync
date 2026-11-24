#!/bin/zsh
# Builds Project Drive Sync (Release) and places it on the Desktop.
set -euo pipefail
cd "${0:A:h}"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
BUILD_DIR="$(mktemp -d)"
xcodebuild -project ProjectDriveSync.xcodeproj -scheme ProjectDriveSync -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build | grep -E "error:|BUILD" || true
APP="$BUILD_DIR/Build/Products/Release/ProjectDriveSync.app"
[[ -d "$APP" ]] || { echo "Build failed"; exit 1; }
DEST="$HOME/Desktop/Project Drive Sync.app"
pkill -f "Project Drive Sync.app/Contents/MacOS" 2>/dev/null || true
rm -rf "$DEST"
ditto "$APP" "$DEST"
rm -rf "$BUILD_DIR"
echo "Installed: $DEST"
