#!/usr/bin/env bash
# Build a Developer ID-signed, notarised, stapled DMG in $OPENRIG_BUILD_ROOT/dist.
# Needs a Developer ID Application cert and a notarytool keychain profile
# ($OPENRIG_NOTARY_PROFILE, default "openrig"): `xcrun notarytool store-credentials openrig`.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh

profile="${OPENRIG_NOTARY_PROFILE:-openrig}"

identity_line="$(security find-identity -v -p codesigning | grep -m1 '"Developer ID Application: ' || true)"
[[ -n "$identity_line" ]] || fail "no Developer ID Application identity in the keychain"
identity="$(awk '{print $2}' <<<"$identity_line")"
team="$(sed -E 's/.*\(([A-Z0-9]+)\)".*/\1/' <<<"$identity_line")"

# Fail before the build, not after it: a missing profile or an expired Apple agreement both show here.
if ! err="$(xcrun notarytool history --keychain-profile "$profile" 2>&1 >/dev/null)"; then
    fail "notarytool profile \"$profile\" doesn't work (set OPENRIG_NOTARY_PROFILE to use another): $err"
fi

# CFBundleShortVersionString must be numeric, so only vX.Y.Z tags count.
tag="$(stable_tag --merged HEAD)"
version="${tag#v}"
[[ -n "$tag" ]] || version="$(project_version)"
build="$(git rev-list --count HEAD)"
dmg="$dist/OpenRig-$version.dmg"

echo "==> OpenRig $version ($build), team $team"
rm -rf "$dist"
mkdir -p "$dist"

xcodegen generate --quiet
# -skipPackagePluginValidation: SwiftTerm's build-info plugin otherwise needs "Trust & Enable" for this derived data path.
xcodebuild archive -project OpenRig.xcodeproj -scheme OpenRig -configuration Release \
    -archivePath "$dist/OpenRig.xcarchive" -derivedDataPath "$build_root/DistDerivedData" \
    -destination 'generic/platform=macOS' -skipPackagePluginValidation -quiet \
    OPENRIG_SIGN_IDENTITY="$identity" OPENRIG_TEAM="$team" OTHER_CODE_SIGN_FLAGS=--timestamp \
    MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build"

app="$dist/OpenRig.xcarchive/Products/Applications/OpenRig.app"
codesign --verify --deep --strict "$app"

echo "==> DMG"
stage="$dist/stage"
mkdir -p "$stage"
ditto "$app" "$stage/OpenRig.app"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname OpenRig -srcfolder "$stage" -format UDZO "$dmg"
rm -rf "$stage"
codesign --sign "$identity" --timestamp "$dmg"

echo "==> Notarising (a few minutes)"
xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait --output-format json >"$dist/notary.json"
status="$(plutil -extract status raw -o - "$dist/notary.json")"
if [[ "$status" != "Accepted" ]]; then
    echo "error: notarisation status $status" >&2
    xcrun notarytool log "$(plutil -extract id raw -o - "$dist/notary.json")" --keychain-profile "$profile" >&2
    exit 1
fi
xcrun stapler staple -q "$dmg"
xcrun stapler validate -q "$dmg"

echo "==> Gatekeeper"
spctl -a -t open --context context:primary-signature -v "$dmg"
mnt="$(mktemp -d)"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mnt" "$dmg"
trap 'hdiutil detach -quiet "$mnt"' EXIT
spctl -a -t exec -vv "$mnt/OpenRig.app"

echo "==> $dmg"
echo "version $version, build $build, $(stat -f %z "$dmg") bytes"
echo "sha256 $(shasum -a 256 "$dmg" | awk '{print $1}')"
