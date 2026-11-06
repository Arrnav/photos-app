#!/bin/sh
# Rebuilds, re-signs (creating a new free certificate/profile if needed) and
# installs an optimised (Release) build of Photos on a connected iPhone. Usage: Scripts/reinstall.sh <device-udid>
# Find the UDID with: xcrun devicectl list devices
set -eu

if [ $# -ne 1 ]; then
  echo "Usage: $0 <device-udid>   (see: xcrun devicectl list devices)" >&2
  exit 64
fi
DEVICE=$1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP="$ROOT/build/DerivedData/Build/Products/Release-iphoneos/Photos.app"

cd "$ROOT"
xcodegen generate --quiet
xcodebuild -project Photos.xcodeproj -scheme Photos -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData \
  -allowProvisioningUpdates -quiet build

PROFILE=$(mktemp)
trap 'rm -f "$PROFILE"' EXIT
security cms -D -i "$APP/embedded.mobileprovision" > "$PROFILE"
echo "Profile expires: $(plutil -extract ExpirationDate raw -o - "$PROFILE")"

xcrun devicectl device install app --device "$DEVICE" "$APP"
echo "Installed. Launch Photos on the phone."
