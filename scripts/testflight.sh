#!/usr/bin/env bash
# Archive the iPhone app (OpenRigRemote) and upload it to App Store Connect for TestFlight.
# Needs your Apple ID in Xcode › Settings › Accounts: the upload and automatic signing use it.
# Team: $OPENRIG_TEAM, else the Developer ID identity's team. Build number: $OPENRIG_BUILD_NUMBER, else the commit count.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh

team="${OPENRIG_TEAM:-}"
if [[ -z "$team" ]]; then
    identity_line="$(security find-identity -v -p codesigning | grep -m1 '"Developer ID Application: ' || true)"
    [[ -n "$identity_line" ]] || fail "set OPENRIG_TEAM: no Developer ID Application identity to read the team from"
    team="$(sed -E 's/.*\(([A-Z0-9]+)\)".*/\1/' <<<"$identity_line")"
fi
# App Store Connect rejects a build number it has seen for this version.
build="${OPENRIG_BUILD_NUMBER:-$(git rev-list --count HEAD)}"

out="$build_root/testflight"
archive="$out/OpenRigRemote.xcarchive"
echo "==> OpenRigRemote build $build, team $team"
rm -rf "$out"
mkdir -p "$out"

xcodegen generate --quiet
xcodebuild archive -project OpenRig.xcodeproj -scheme OpenRigRemote -configuration Release \
    -archivePath "$archive" -derivedDataPath "$build_root/TestFlightDerivedData" \
    -destination 'generic/platform=iOS' -skipPackagePluginValidation -allowProvisioningUpdates -quiet \
    OPENRIG_TEAM="$team" CURRENT_PROJECT_VERSION="$build"

options="$out/ExportOptions.plist"
plutil -create xml1 "$options"
plutil -insert method -string app-store-connect "$options"
plutil -insert destination -string upload "$options"
plutil -insert teamID -string "$team" "$options"

echo "==> Uploading"
# Export runs /usr/bin/rsync (openrsync), which starts its other end as the first `rsync` on PATH.
# Homebrew's rsync 3.x rejects openrsync's options, and the export fails with "Copy failed".
PATH="/usr/bin:$PATH" xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$options" \
    -exportPath "$out/export" -allowProvisioningUpdates
echo "Uploaded build $build. It appears in App Store Connect › TestFlight once processing finishes."
