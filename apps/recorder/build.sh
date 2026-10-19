#!/bin/bash
# Builds Studio Recorder (Release, ad-hoc signed) into apps/recorder/build.
# It never installs anything. Run the printed .app path to open it.
set -euo pipefail

cd "$(dirname "$0")"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is not installed. Install it with: brew install xcodegen" >&2
  exit 1
fi
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild is not available. Install Xcode from the App Store, then run: sudo xcode-select -s /Applications/Xcode.app" >&2
  exit 1
fi

xcodegen generate --quiet

xcodebuild \
  -project StudioRecorder.xcodeproj \
  -scheme StudioRecorder \
  -configuration Release \
  -derivedDataPath build/DerivedData \
  CONFIGURATION_BUILD_DIR="$PWD/build" \
  -quiet build 2>&1 | tail -n 15

APP="$PWD/build/Studio Recorder.app"
if [ ! -d "$APP" ]; then
  echo "The build finished but the app was not found at: $APP" >&2
  exit 1
fi
echo
echo "Built: $APP"
