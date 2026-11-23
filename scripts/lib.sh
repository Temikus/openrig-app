# shellcheck shell=bash disable=SC2034
# Shared by the release scripts. Callers cd to the repo root before sourcing.

fail() { echo "error: $*" >&2; exit 1; }

# Build output stays outside the repo so iCloud Drive doesn't sync it (same default as the justfile).
build_root="${OPENRIG_BUILD_ROOT:-$HOME/Library/Caches/openrig-app}"
dist="$build_root/dist"

# Newest vX.Y.Z tag, skipping prerelease and suffixed tags. Extra args go to `git tag`.
stable_tag() { git tag --list 'v*' --sort=-v:refname "$@" | awk '/^v[0-9]+\.[0-9]+\.[0-9]+$/ && !f { print; f = 1 }'; }

project_version() { sed -nE 's/^ *MARKETING_VERSION: "?([0-9.]+)"?/\1/p' project.yml; }
