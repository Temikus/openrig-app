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
build *flags: gen
    xcodebuild {{ flags }} -project OpenRig.xcodeproj -scheme OpenRig -configuration Debug \
        -destination "generic/platform=macOS" -derivedDataPath {{ quote(derived) }} -quiet build

# Run package tests; live-daemon tests skip themselves when no daemon answers
test:
    swift test {{ spm }}

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
