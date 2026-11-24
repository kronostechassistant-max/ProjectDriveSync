#!/bin/zsh
# Builds Digital Drive Linkages (Release, Apple Silicon + Intel).
#   ./build-and-install.sh            puts it on the Desktop, replacing the copy there
#   ./build-and-install.sh --package  also makes the release file in build/
set -euo pipefail
cd "${0:A:h}"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
DEST="$HOME/Desktop/Digital Drive Linkages.app"
# Never stop a running copy: it could be in the middle of a sync.
if pgrep -U "$UID" -f "$DEST/Contents/MacOS" >/dev/null; then echo "Quit Digital Drive Linkages first, then run this again."; exit 1; fi
BUILD_DIR="$(mktemp -d)"; trap 'rm -rf "$BUILD_DIR"' EXIT
xcodebuild -project DigitalDriveLinkages.xcodeproj -scheme DigitalDriveLinkages -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$BUILD_DIR" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build | grep -E "error:|BUILD" || true
APP="$BUILD_DIR/Build/Products/Release/Digital Drive Linkages.app"
[[ -d "$APP" ]] || { echo "Build failed"; exit 1; }
# Public downloads must not carry this Mac's folder paths or the debugging permission.
xcrun strip -S "$APP/Contents/MacOS/Digital Drive Linkages" 2>/dev/null
codesign -f -s - --identifier com.kronostechnologies.ProjectDriveSync "$APP" 2>/dev/null
codesign --verify --deep --strict "$APP"
if grep -rqaF -e "$HOME/" -e "$BUILD_DIR" "$APP"; then echo "The build contains a folder path from this Mac. Stopped."; exit 1; fi
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q get-task-allow; then echo "The build still allows debugging. Stopped."; exit 1; fi
if [[ "${1:-}" == "--package" ]]; then
  V=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
  N=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
  mkdir -p build; ZIP="build/DigitalDriveLinkages-$V-build$N.zip"; rm -f "$ZIP"
  ditto "$APP" "$BUILD_DIR/Digital Drive Linkages.app"
  ditto -c -k --keepParent "$BUILD_DIR/Digital Drive Linkages.app" "$ZIP"
  echo "Packaged: $ZIP"; shasum -a 256 "$ZIP"
fi
rm -rf "$DEST"
ditto "$APP" "$DEST"
echo "Installed: $DEST"
