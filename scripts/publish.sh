#!/usr/bin/env bash
# Push HEAD's vX.Y.Z tag and publish the DMG from `just dist` as a GitHub release.
# Safe to rerun after a failure: pushing the same tag again does nothing.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh

tag="$(stable_tag --points-at HEAD)"
[[ -n "$tag" ]] || fail "HEAD isn't a vX.Y.Z tag"
[[ -z "$(git status --porcelain)" ]] || fail "working tree isn't clean"
version="${tag#v}"
build="$(git rev-list --count HEAD)"
dmg="$dist/OpenRig-$version.dmg"
[[ -f "$dmg" ]] || fail "no $dmg; run \`just dist\` first"

# Check the DMG itself, not the archive: notarised, and holding the app built from HEAD.
xcrun stapler validate -q "$dmg" || fail "$dmg isn't stapled; run \`just dist\` again"
spctl -a -t open --context context:primary-signature "$dmg" || fail "Gatekeeper rejects $dmg"
mnt="$(mktemp -d)"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mnt" "$dmg"
trap 'hdiutil detach -quiet "$mnt"' EXIT
spctl -a -t exec "$mnt/OpenRig.app" || fail "Gatekeeper rejects the app in $dmg"
plist="$mnt/OpenRig.app/Contents/Info.plist"
built="$(plutil -extract CFBundleVersion raw -o - "$plist")"
built_version="$(plutil -extract CFBundleShortVersionString raw -o - "$plist")"
[[ "$built" == "$build" && "$built_version" == "$version" ]] ||
    fail "$dmg holds $built_version ($built), HEAD is $version ($build); run \`just dist\` again"
hdiutil detach -quiet "$mnt"
trap - EXIT

gh release view "$tag" >/dev/null 2>&1 && fail "$tag is already released on GitHub"

# release.sh tags with the bare tag name when there are no notes; let GitHub write them then.
notes="$(git tag -l --format='%(contents)' "$tag")"
if [[ -n "$notes" && "$notes" != "$tag" ]]; then
    notes_args=(--notes "$notes")
else
    notes_args=(--generate-notes)
fi

echo "==> Pushing $tag"
git push origin "$tag"

echo "==> Releasing $tag"
gh release create "$tag" "$dmg" --verify-tag --title "OpenRig $version" "${notes_args[@]}"
