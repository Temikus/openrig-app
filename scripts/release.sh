#!/usr/bin/env bash
# Tag the next version, build its notarised DMG, then push the tag and publish a GitHub release.
# Usage: release.sh [patch|minor|major] [notes]   (without notes, GitHub generates them)
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh

bump="${1:-patch}"
[[ "$bump" =~ ^(patch|minor|major)$ ]] || fail "bump must be patch, minor or major"
[[ "$(git branch --show-current)" == main ]] || fail "not on main"
[[ -z "$(git status --porcelain)" ]] || fail "working tree isn't clean"
gh auth status >/dev/null 2>&1 || fail "gh isn't logged in; run \`gh auth login\`"
git fetch -q origin main --tags
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "main isn't in sync with origin/main"

last="$(stable_tag --merged HEAD)"
if [[ -z "$last" ]]; then
    # First release ships project.yml's version as is.
    next="$(project_version)"
    last="none"
else
    IFS=. read -r major minor patch <<<"${last#v}"
    case "$bump" in
        major) next="$((major + 1)).0.0" ;;
        minor) next="$major.$((minor + 1)).0" ;;
        patch) next="$major.$minor.$((patch + 1))" ;;
    esac
fi
tag="v$next"

read -r -p "Release $tag from $(git rev-parse --short HEAD) (last: $last)? [y/N] " answer
[[ "$answer" == [yY] ]] || exit 1

# The tag message carries the release notes; without notes it's just the tag name.
git tag -a "$tag" -m "${2:-$tag}"
if ! just dist; then
    git tag -d "$tag"
    fail "dist failed; deleted local tag $tag"
fi
just dist-publish || fail "publish failed; fix it and run \`just dist-publish\`"
