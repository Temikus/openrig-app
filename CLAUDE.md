# OpenRig app: notes for agents

Tasks are in the `justfile` (`just build`, `just test`, `just lint`). Decisions and the `OPENRIG_DEBUG_*` launch hooks are recorded in `PLAN.md`.

## Checking the UI without disturbing the person

The person uses this laptop while you work. Never take the pointer, the keyboard or focus. The snippets below were run as written on macOS 27 (2026-11-20) with another app in front, and focus did not move.

**Do not** use `just run`, plain `open`, `osascript ... activate`, computer-use clicks or typing, full-screen `screencapture`, or XCUITest. Each one steals focus or the pointer.

### 1. Launch your own copy in the background

```bash
: "${OPENRIG_BUILD_ROOT:?set it to ~/Library/Caches/openrig-app/seats/<your member id>}"
just build -skipPackagePluginValidation OPENRIG_ID_SUFFIX=.agent
APP="$OPENRIG_BUILD_ROOT/DerivedData/Build/Products/Debug/OpenRig.app"
[ "$(defaults read "$APP/Contents/Info" CFBundleIdentifier)" = dev.openrig.OpenRig.agent ] || { echo "not the .agent build" >&2; exit 1; }
BIN="OpenRig.app/Contents/MacOS/OpenRig"
before=$(pgrep -f "$BIN")
open -g -n --env OPENRIG_DEBUG_OPEN=kernel/queue --env OPENRIG_DEBUG_SIZE=900x600 "$APP" \
    --args -menuBarItem NO -bannerKinds '()'
# Your pid is the one that was not running before.
n=0; until PID=$(pgrep -f "$BIN" | grep -vxF "${before:-none}" | head -1) && [ -n "$PID" ]; do
    n=$((n + 1)); [ "$n" -gt 30 ] && break; sleep 1
done
```

- `-g` keeps the app behind the person's windows. `-n` starts a new copy.
- `OPENRIG_ID_SUFFIX=.agent` gives your copy its own bundle id and settings (`dev.openrig.OpenRig.agent`). The person's copy uses `dev.openrig.OpenRig`: never write to it.
- `OPENRIG_BUILD_ROOT` is your own build folder, so you never launch or overwrite the person's build. The justfile and `APP` both read it. `just --set build_root` does not set it.
- `-menuBarItem NO` keeps your copy out of the person's menu bar. `-bannerKinds '()'` stops it posting banners. A new bundle id would otherwise ask for notification permission on the person's screen.
- `-bannerKinds '()'` also silences `OPENRIG_DEBUG_BANNERS` and `OPENRIG_DEBUG_PROMPT_AFTER`. Leave it out only to test banners. That copy then asks for notification permission on the person's screen, so ask the lead first.
- A copy may already be running. It is the person's: do not drive, relaunch or quit it.
- Set the state you need with `OPENRIG_DEBUG_*` hooks at launch, not with clicks.
- When done, `kill "$PID"`. Never `pkill` or `killall` OpenRig.

### 2. Capture the window by ID

A capture by window ID shows the window even when other windows cover it.

```bash
wid() {  # prints "<window id> <title>" for each of your copy's windows
    PID=$PID swift - <<'EOF'
import CoreGraphics
import Foundation
let pid = Int(ProcessInfo.processInfo.environment["PID"]!)!
for w in CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
where w[kCGWindowOwnerPID as String] as? Int == pid && w[kCGWindowLayer as String] as? Int == 0 {
    print(w[kCGWindowNumber as String]!, w[kCGWindowName as String] ?? "")
}
EOF
}
# The hooks apply a few seconds after the window appears: wait for the title they produce.
n=0; until wid | grep -q " kernel"; do n=$((n + 1)); [ "$n" -gt 30 ] && break; sleep 1; done
WID=$(wid | head -1 | cut -d' ' -f1)
screencapture -x -o -l "$WID" <scratchpad>/shot.png
```

### 3. Press controls through accessibility

`AXPress` goes to the control itself. The pointer does not move and the app stays in the background.

```bash
P="tell application \"System Events\" to tell (first process whose unix id is $PID)"
osascript -e "$P to get entire contents of toolbar 1 of window 1"   # find the control
TAB="radio button 3 of radio group 1 of group 1 of toolbar 1 of window 1"   # Terminals
# A press right after launch did not always show: press until the control reports the new value, then capture.
n=0; until [ "$(osascript -e "$P to get value of $TAB")" = 1 ]; do
    n=$((n + 1)); [ "$n" -gt 15 ] && break
    osascript -e "$P to perform action \"AXPress\" of $TAB" >/dev/null; sleep 1
done
```

Address the process by pid, never by name: the person's copy has the same name. For the full tree, use `OPENRIG_DEBUG_AX=<file>`.

### What this cannot check

Real pointer, keyboard and focus behaviour: typing into a tile (Type mode), Tab order by real key presses, drag, hover. Do not fall back to taking the pointer. Say what is unverified and ask the person, who can test it or lend the screen.

## Diagnosing a crash or a spin

- Read the exception text first. The crash report leaves it out; the system log keeps it, with AppKit's layout-pass trace: `/usr/bin/log show --start "<time>" --end "<time>" --predicate 'process == "OpenRig"'`. Use the full path: `log` is a zsh builtin.
- Compare the log's stack with a known bug's before calling them the same.
- A background copy never drives the Touch Bar, so it survives layout loops that abort the person's copy. Watch its CPU (`ps -o %cpu= -p "$PID"`) and take a `sample "$PID" 3` while it is high.
- Resize without the pointer: `osascript -e "$P to set size of window 1 to {900, 600}"`. `OPENRIG_DEBUG_WIDTHS=<file>` traces the pane widths.
