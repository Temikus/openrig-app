# OpenRig app: notes for agents

Tasks are in the `justfile` (`just build`, `just test`, `just lint`). Decisions and the `OPENRIG_DEBUG_*` launch hooks are recorded in `PLAN.md`.

## Checking the UI without disturbing the person

The person uses this laptop while you work. Never take the pointer, the keyboard or focus. The snippets below were run as written on macOS 27 (2026-11-20) with another app in front, and focus did not move.

**Do not** use `just run`, plain `open`, `osascript ... activate`, computer-use clicks or typing, full-screen `screencapture`, or XCUITest. Each one steals focus or the pointer.

### 1. Launch your own copy in the background

```bash
APP=~/Library/Caches/openrig-app/DerivedData/Build/Products/Debug/OpenRig.app
BIN="OpenRig.app/Contents/MacOS/OpenRig"
before=$(pgrep -f "$BIN")
open -g -n --env OPENRIG_DEBUG_OPEN=kernel/queue --env OPENRIG_DEBUG_SIZE=900x600 "$APP" --args -menuBarItem NO
# Your pid is the one that was not running before.
n=0; until PID=$(pgrep -f "$BIN" | grep -vxF "${before:-none}" | head -1) && [ -n "$PID" ]; do
    n=$((n + 1)); [ "$n" -gt 30 ] && break; sleep 1
done
```

- `-g` keeps the app behind the person's windows. `-n` starts a new copy.
- `-menuBarItem NO` keeps your copy out of the person's menu bar. It shares their settings, where the item is on by default.
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
