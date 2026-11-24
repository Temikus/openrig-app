# OpenRig for macOS

[![CI](https://github.com/Temikus/openrig-app/actions/workflows/ci.yml/badge.svg)](https://github.com/Temikus/openrig-app/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)

A native SwiftUI app for [OpenRig](https://openrig.dev): see what each agent seat in a rig is doing, spot what needs you, and act on it.

<img width="1712" height="777" alt="Screenshot 2026-11-23 at 10 20 35 am" src="https://github.com/user-attachments/assets/ba8f027c-d98f-4478-b3e6-65f957b519ba" />

It talks to the local `rig` daemon. Reads use the daemon's HTTP API; actions run the `rig` CLI. See [PLAN.md](PLAN.md) for the design and milestones.

**Status:** v1 milestones M0–M6 done: canvas, queue board, terminals, actions, permission prompts, and offline handling.

## Requirements

- macOS 27 and Xcode 27 or later
- [`just`](https://github.com/casey/just) and [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install just xcodegen`
- OpenRig 0.7.x with the daemon running (`rig daemon start`)

## Usage

```sh
just run      # generate the Xcode project, build, and launch
just install         # same as install-canary
just install-canary  # build Release as "OpenRig Canary" (yellow icon) and copy it to /Applications
just install-public  # download the latest GitHub release and install it as OpenRig.app
just test     # package tests (live-daemon tests skip if no daemon answers)
just lint     # swift format lint
just --list   # everything else
```

A queue row shows a thumbnail of each image it points at; click one to open it in Quick Look, and use the arrow keys to see the rest. To attach images to a row, put them in one folder, named in the order you'll talk about them (`1-app-shape.png`, `2-question-screen.png`). Pass the folder as `--evidence-ref`, or name it or the files in the body. Paths can be absolute, `~/`, or relative to the folder the sending seat was launched in. The app reads them from disk, so it shows them only when the daemon runs on the same Mac.

## iPhone

The iPhone app shows what waits on you and lets you act on it from your phone. The code is in `Remote/`, scheme `OpenRigRemote`. It reaches the Mac on the same Wi-Fi, through a relay in the Mac app. The daemon stays on loopback.
- The Mac app must be running. A sleeping Mac answers nothing.
- iOS 26 or later.

**What the phone can do**
- **Answer asks:** pick from their options, or reply in your own words.
- **Answer a seat's permission prompt,** from Needs you or from the seat in the Rigs tab. It opens on its own screen with the command in full. Allow once stays off until you've seen the end of a long command, and Decline asks for an optional reason. If the prompt changes before you answer, the buttons go and nothing is sent; Show the new prompt loads the new one. "Always allow" stays on the Mac.
- **Act on rows waiting on you:** Reply, Got it and Done.
- **See each rig's seats** in the Rigs tab. A rig's count is what Needs you lists for it.
- **Message a seat, or queue it a task,** from the Rigs tab. Message is off while the seat is stopped at a prompt.

**Install it on your iPhone**
1. Run `just gen`, then open `OpenRig.xcodeproj` in Xcode.
2. Choose the **OpenRigRemote** scheme and your iPhone. The phone needs Developer Mode on (Settings › Privacy & Security).
3. Under Signing & Capabilities, choose your team. The project leaves the team empty, and `just gen` empties it again. Command-line builds read it from `OPENRIG_TEAM`.
4. Run (⌘R).

With a free Apple ID, the app stops opening after 7 days. Run it from Xcode again to renew it.

`just build-ios` builds for the simulator only, as CI does.

**Pair it**
1. **Check which OpenRig is running on the Mac.**
   - OpenRig Canary (from `just install`) or a release listens on the Wi-Fi.
   - A Debug build (`just run`) listens only on this Mac. Start it with the Wi-Fi switch first: see "Debug builds and the Wi-Fi" below. Otherwise the phone says "Can't reach".
2. On the Mac, open OpenRig › Settings › Phone and choose **Pair a Phone…**. A code and a link appear.
3. On the phone, choose **Scan the code**. If the camera is off, choose **Copy Link** on the Mac, then **Paste** on the phone. Pasting from the Mac needs Handoff on both, signed in to the same Apple ID.
4. Allow Local Network access when iOS asks. It asks once. Without it the phone can't reach the Mac. To turn it on later, use the app's **Open Settings** button.

The phone answers as the person the Mac app acts as. The relay listens on port 7434, or on a free port if that one is taken; the code carries the port. It listens only while "Let paired phones connect" is on and a phone is paired or a code is showing.

**Debug builds and the Wi-Fi**

A Debug build of the Mac app, including `just run`, binds its relay to 127.0.0.1, so only the simulator can connect. Release builds, including OpenRig Canary, listen on the Wi-Fi.

To try a real phone with a Debug build:
1. Quit OpenRig.
2. Start it with the Wi-Fi switch:

```sh
just build
open --env OPENRIG_RELAY_WIFI=1 ~/Library/Caches/openrig-app/DerivedData/Build/Products/Debug/OpenRig.app
```

`OPENRIG_RELAY_WIFI=1 just run` doesn't work: `open` doesn't pass on your shell's environment. macOS may ask once whether OpenRig may accept incoming connections.

**Unpair it**
- **On the Mac,** Settings › Phone › **Unpair** cuts the phone off at once. It revokes the phone's credential and drops its key from the relay.
- The phone may then say "Can't reach" rather than "unpaired": iOS doesn't always report the refused connection.
- **On the phone,** **Unpair this phone** in its Settings only forgets the Mac on the phone.

## Releasing

`just release [patch|minor|major] ["notes"]` runs on a clean, pushed `main`. It tags the next version, builds a Developer ID-signed, notarised DMG, pushes the tag and publishes it as a [GitHub release](https://github.com/Temikus/openrig-app/releases). Without notes, GitHub generates them. The first release uses `MARKETING_VERSION` from `project.yml`.

It needs a Developer ID Application certificate in the keychain, `gh auth login`, and a notarytool profile: `xcrun notarytool store-credentials openrig` (or set `OPENRIG_NOTARY_PROFILE`). `just dist` and `just dist-publish` run the build and publish steps on their own.

The app finds the daemon the way the CLI does: `OPENRIG_URL`, then `$OPENRIG_HOME/daemon.json` (default `~/.openrig`), then `http://127.0.0.1:7433`.

**Settings (⌘,)** can override that with a custom address, store an operator token in the Keychain, and point at a `rig`, `tmux` or `node` the app didn't find (common with nvm, asdf or mise). The same address and token reach the `rig` commands the app runs. Settings also covers who the app acts as, Open at login, the Dock badge and menu bar list, banners, and terminal typing.

**First build:** SwiftTerm ships a small build plugin that Xcode must approve once. Open `OpenRig.xcodeproj` (after `just gen`), build with ⌘B, and click **Trust & Enable** for SwiftTermBuildInfoPlugin. CI skips that prompt with `just build -skipPackagePluginValidation`; local builds don't need the flag.

Build output goes to `~/Library/Caches/openrig-app` (override with `OPENRIG_BUILD_ROOT`) so it stays out of synced folders. `OpenRig.xcodeproj` is generated by `just gen` and not committed.

## Layout

| Path | What |
|---|---|
| `OpenRigKit/Sources/RigModel` | Daemon payload types, decoded leniently because the HTTP API is internal |
| `OpenRigKit/Sources/RigClient` | Daemon discovery, HTTP reads, and the event stream |
| `OpenRigKit/Sources/RigCanvasLayout` | Pod and seat layout, and the orthogonal wire router |
| `OpenRigKit/Sources/RigDomain` | Pure logic that turns daemon data into what the views show |
| `App/` | SwiftUI app |
| `project.yml` | XcodeGen spec for the app target |

## License

[Apache 2.0](LICENSE)
