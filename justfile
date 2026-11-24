set shell := ["bash", "-euo", "pipefail", "-c"]

# xcode-select may point at the Command Line Tools, which can't build the app.
export DEVELOPER_DIR := env("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")

# Build output lives outside the repo so iCloud Drive doesn't sync it.
build_root := env("OPENRIG_BUILD_ROOT", home_directory() / "Library/Caches/openrig-app")
spm := "--package-path OpenRigKit --scratch-path " + quote(build_root / "spm")
derived := build_root / "DerivedData"
fixtures := "OpenRigKit/Tests/RigFixtures/Fixtures"
daemon := env("OPENRIG_URL", "http://127.0.0.1:7433")

default:
    @just --list

# Generate OpenRig.xcodeproj from project.yml
gen:
    xcodegen generate --quiet

# Build the app (Debug, ad-hoc signed). Extra xcodebuild flags pass through.
build *flags: (_xcodebuild "Debug" flags)

# Builds for this Mac's architecture only; `just dist` builds the universal app.
# ONLY_ACTIVE_ARCH keeps Release from adding the other architecture.
_xcodebuild config *flags: gen
    xcodebuild {{ flags }} -project OpenRig.xcodeproj -scheme OpenRig -configuration {{ config }} \
        -destination "platform=macOS,arch=$(uname -m)" ONLY_ACTIVE_ARCH=YES \
        -derivedDataPath {{ quote(derived) }} -quiet build

alias install := install-canary

# Build a Release copy as OpenRig Canary and install it beside the public app (quit the canary first)
install-canary *flags: (_xcodebuild "Release" "OPENRIG_ID_SUFFIX=.canary" "OPENRIG_ICON=AppIconCanary" "OPENRIG_APP_NAME='OpenRig Canary'" flags)
    #!/usr/bin/env bash
    set -euo pipefail
    dest="/Applications/OpenRig Canary.app"
    if pgrep -f "^$dest/Contents/MacOS/OpenRig" >/dev/null; then
      echo "Quit $dest first; it is running." >&2; exit 1
    fi
    rm -rf "$dest"
    ditto {{ quote(derived / "Build/Products/Release/OpenRig.app") }} "$dest"
    echo "Installed $dest"

# Download the latest GitHub release and install it as /Applications/OpenRig.app (quit it first)
install-public:
    #!/usr/bin/env bash
    set -euo pipefail
    dest="/Applications/OpenRig.app"
    if pgrep -f "^$dest/Contents/MacOS/OpenRig" >/dev/null; then
      echo "Quit $dest first; it is running." >&2; exit 1
    fi
    tmp="$(mktemp -d)"
    mnt="$tmp/mnt"
    trap 'hdiutil detach -quiet "$mnt" 2>/dev/null || true; rm -rf "$tmp"' EXIT
    tag="$(gh release view --json tagName -q .tagName)"
    gh release download "$tag" --pattern 'OpenRig-*.dmg' --dir "$tmp"
    dmg="$(echo "$tmp"/OpenRig-*.dmg)"
    spctl -a -t open --context context:primary-signature "$dmg"
    mkdir "$mnt"
    hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mnt" "$dmg"
    spctl -a -t exec "$mnt/OpenRig.app"
    rm -rf "$dest"
    ditto "$mnt/OpenRig.app" "$dest"
    echo "Installed OpenRig $tag at $dest"

# Build a Developer ID-signed, notarised DMG in <build root>/dist (version from the latest v* tag)
dist:
    OPENRIG_BUILD_ROOT={{ quote(build_root) }} ./scripts/dist.sh

# Push HEAD's v* tag and publish the DMG from `just dist` as a GitHub release
dist-publish:
    OPENRIG_BUILD_ROOT={{ quote(build_root) }} ./scripts/publish.sh

# Tag the next version, then dist, push the tag and publish a GitHub release (asks first)
[positional-arguments]
release bump="patch" notes="":
    ./scripts/release.sh "$@"

# List GitHub releases
releases:
    gh release list

# Run package tests; live-daemon tests skip themselves when no daemon answers
test:
    swift test {{ spm }}

# Tests that write to the real queue: one self-addressed qitem, created and closed by the test
test-live:
    OPENRIG_LIVE_WRITES=1 swift test {{ spm }} --filter LiveWriteTests

# The app's write actions as its person, against a throwaway seat (it messages that seat's agent)
test-rig seat:
    OPENRIG_TEST_SEAT={{ quote(seat) }} swift test {{ spm }} --filter LiveTestRigTests

# Stop, start and resume one seat of a throwaway rig through the CLI (stops that whole rig)
test-lifecycle rig:
    OPENRIG_TEST_RIG={{ quote(rig) }} swift test {{ spm }} --filter LiveLifecycleTests

# Check formatting
lint:
    swift format lint --strict --recursive OpenRigKit/Package.swift OpenRigKit/Sources OpenRigKit/Tests App

# Fix formatting in place
format:
    swift format --in-place --recursive OpenRigKit/Package.swift OpenRigKit/Sources OpenRigKit/Tests App

# Build and launch the app
run: build
    open {{ quote(derived / "Build/Products/Debug/OpenRig.app") }}

# Re-record decoder fixtures from the local daemon (needs the denkeeper and kernel rigs)
record-fixtures:
    #!/usr/bin/env bash
    set -euo pipefail
    # Scrub per-machine ids so fixtures are stable and carry no resumable session tokens.
    scrub='walk(if type == "object" then
        (if has("resumeToken") and .resumeToken then .resumeToken = "00000000-0000-0000-0000-000000000000" else . end)
        | (if has("observedPid") then .observedPid = 1 else . end)
        | (if (.generation | type) == "string" then .generation = "gen-0" else . end)
      else . end)'
    curl -sf {{ daemon }}/healthz | jq '.pid = 1 | .selfHostId = "host-00000000"' > {{ fixtures }}/healthz.json
    curl -sf {{ daemon }}/api/ps > {{ fixtures }}/ps.json
    for rig in denkeeper kernel; do
      id=$(jq -r --arg n "$rig" '.[] | select(.name == $n) | .rigId' {{ fixtures }}/ps.json)
      curl -sf "{{ daemon }}/api/rigs/$id/graph" | jq "$scrub" > "{{ fixtures }}/graph-$rig.json"
    done
    # Queue rows carry agents' free text; keep the structure, replace the words.
    text='map(. + {summary: ("Summary of " + .qitemId[-4:]), body: "Body text.", resolution: (if .resolution then "Resolution text." else null end),
        humanDetail: null, humanIntent: null, humanAnswers: null, delegatedDecision: null, evidenceRef: null})'
    curl -sf "{{ daemon }}/api/queue/list?rig=denkeeper&limit=500" | jq "$text" > {{ fixtures }}/queue-denkeeper.json
    echo "Recorded. Review the diff before committing."

# Remove build output
clean:
    rm -rf {{ quote(build_root) }} OpenRig.xcodeproj App/Info.plist
