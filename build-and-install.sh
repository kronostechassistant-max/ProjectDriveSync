#!/bin/zsh
# Builds Project Drive Sync (Release, Apple Silicon + Intel).
#   ./build-and-install.sh            puts it on the Desktop, replacing the copy there
#   ./build-and-install.sh --package  also makes the release file in build/
set -euo pipefail
cd "${0:A:h}"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
DEST="$HOME/Desktop/Project Drive Sync.app"
# Never stop a running copy: it could be in the middle of a sync.
if pgrep -U "$UID" -f "$DEST/Contents/MacOS" >/dev/null; then echo "Quit Project Drive Sync first, then run this again."; exit 1; fi
BUILD_DIR="$(mktemp -d)"; trap 'rm -rf "$BUILD_DIR"' EXIT
xcodebuild -project ProjectDriveSync.xcodeproj -scheme ProjectDriveSync -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$BUILD_DIR" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build | grep -E "error:|BUILD" || true
APP="$BUILD_DIR/Build/Products/Release/ProjectDriveSync.app"
[[ -d "$APP" ]] || { echo "Build failed"; exit 1; }
codesign --verify --deep --strict "$APP"
if [[ "${1:-}" == "--package" ]]; then
  V=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
  N=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
  mkdir -p build; ZIP="build/ProjectDriveSync-$V-build$N.zip"; rm -f "$ZIP"
  ditto "$APP" "$BUILD_DIR/Project Drive Sync.app"
  ditto -c -k --keepParent "$BUILD_DIR/Project Drive Sync.app" "$ZIP"
  echo "Packaged: $ZIP"; shasum -a 256 "$ZIP"
fi
rm -rf "$DEST"
ditto "$APP" "$DEST"
echo "Installed: $DEST"
