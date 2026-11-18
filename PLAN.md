# OpenRig macOS app v1: implementation plan

## 1. Findings (rig 0.7.11)

### What the daemon exposes
- **Local HTTP API on `http://127.0.0.1:7433`.** Port, pid and db path are in `~/.openrig/daemon.json`. `GET /healthz` returns semver, commit and event-loop health.
- **It is a Hono app.** Routes are in `/opt/homebrew/Cellar/openrig/0.7.11/libexec/lib/node_modules/@openrig/cli/daemon/dist/server.js` and `routes/*.js`. The CLI is a thin client over it (`dist/client.js`).
- **Auth.** Unauthenticated loopback GETs returned 200 for `/api/ps`, `/api/rigs/:id/graph`, `/api/attention`, `/api/seat/status/:seat` and `/api/terminal/views`.
  - A "browser boundary" middleware checks Host and Origin on `/api/*`.
  - Transport and terminal routes take a bearer only if `~/.openrig/terminal-token` exists. It does not exist on this machine.
  - Writes record the actor from the `X-OpenRig-Session` header, which the CLI stamps from `OPENRIG_SESSION_NAME`.
- **Push.** `GET /api/events?rigId=&replay=<n>` is SSE with monotonic `id:` and `Last-Event-ID` replay.
  - Event types seen in a 3,000-event replay: `queue.created`, `queue.updated`, `queue.claimed`, `queue.handed_off`, `agent.activity`, `seat.activity_changed`, `node.*`, `rig.*`.
  - Most of the volume is noise to filter: `snapshot.created` and `watchdog.evaluation_skipped`.
  - `/api/queue/watch`, `/api/views/sse` and `/api/watchdog/sse` also exist. `/api/queue/watch` emitted nothing in 4 seconds, so its format is unverified.

### JSON shapes observed
- **`/api/ps`** (same as `rig ps --json`): `rigId, name, nodeCount, runningCount, activeCount, status, lifecycleState, uptime, attentionCount, isArchived`.
- **`/api/rigs/:id/graph`**: `{nodes, edges}` in React Flow shape.
  - Pods are `type:"podGroup"`; seats are `type:"rigNode"` with `parentId`.
  - Seat `data` carries `logicalId, canonicalSessionName, model, status, binding{tmuxSession, tmuxPane}, agentActivity{state, reason, stale}, currentQitems[], needsAttention, heldReason, contextUsedPercentage` and work counts.
  - Edges are `{id, source, target, label}` with label `delegates_to` or `can_observe`.
  - Every `position` is `{0,0}`, so the daemon supplies no layout.
- **`/api/queue/list`** takes `rig, state, destinationSession, sourceSession, activeOnly, compact, handedOffFrom, updatedSince, limit`.
- **`rig queue list --json` rows** carry `qitemId, sourceSession, destinationSession, state, priority, tier, blockedOn, handedOffTo, handedOffFrom, summary, closureReason, closureTarget, closureRequiredAt, claimedAt, lastNudgeResult, resolution`. Per-item reads at `/api/queue/:id` add `chainOfRecord[]`, `body`, `waiting{blocker, liveness, nextBackstop}` and `humanQuestions`.
- **`/api/queue/:id/transitions`** is an append-only log with `actorSession` and `wake{kind, phase}`.
- **`/api/seat/status/:seat`** includes `permission_stop{state, command, origin}`, derived from Claude Code hooks.
- **`rig capture --json`** includes `inputBox` and `activity`.

### tmux
- tmux 3.8, default socket `/private/tmp/tmux-501/default` (from `~/.openrig/tmux-server.json`).
- One session per seat, named `<seat>@<rig>`, with one window and one pane.
- `window-size latest`. Seats already have other clients attached: denkeeper panes are 84x52 and 84x25, kernel panes 200x120.
- The daemon has a terminal WebSocket, `GET /api/terminal/:sessionName`. It runs one `pipe-pane` broker per session, seeds each subscriber with a cursor-safe snapshot, and accepts `{type:"keys"|"text"|"scroll"}` frames with no resize. It is registered only when `ui.enabled` is true, and `rig config get ui.enabled` returns `false` here.

### Gaps the app must cover
1. **No human identity.** `rig whoami` fails outside a seat, and some queue writes without an actor return `400 actor_required`. The app needs a decision on who "you" is.
2. **No planned next hop.** No qitem field carries the design's dashed "next: orch-lead → review-security".
3. **Two encodings of a handoff.** Of 99 rows, 30 are `state:"handed-off"` and 39 are `state:"done", closureReason:"handed_off_to"`.
4. **No link from a permission prompt to a qitem.** It has to be inferred from the seat's `currentQitems`.
5. **Positive `permission_stop` shape unverified.** Every seat reported `unavailable`. It is Claude-only.
6. **No short ids.** Real ids look like `qitem-20261111110308-f963e5f7`; the design's `q-0409` does not exist.
7. **No "asked you" source observed.** `/api/attention` items were empty; `humanQuestions` and `/api/queue/open-human-updates` are the candidates.
8. **`rig queue resolve` route not traced.** It uses the operator-bearer write gate, and its help says loopback daemons without a configured bearer need none.

## 2. Architecture

### Targets
One local SwiftPM package, `OpenRigKit`, plus a thin app target.

| Target | Contents | Dependencies |
|---|---|---|
| `RigModel` | Codable DTOs and domain types (`Rig`, `Seat`, `Pod`, `SpecEdge`, `QItem`, `Transition`, `PermissionStop`) | none |
| `RigClient` | `DaemonLocator`, `DaemonHTTP`, `EventStream`, `RigCLI` | RigModel |
| `RigDomain` | Pure logic: chain reconstruction, Needs-you derivation, selection rule, wire classification | RigModel |
| `RigCanvasLayout` | Pure geometry: pod and seat layout, metro router | swift-collections |
| `RigTerminal` | SwiftTerm wrappers and terminal sources | SwiftTerm |
| `OpenRigApp` | SwiftUI views and `@Observable` stores | all of the above |

### Data layer
- **Reads go direct to HTTP** with `URLSession` and `JSONDecoder`.
  - Spawning the Node CLI per read is too slow for a live UI.
  - The CLI's own `--json` output is these same routes.
- **Push comes from `/api/events`.** Events are invalidation signals, not state: on `queue.*` refetch the queue list, on `seat.activity_changed` or `agent.activity` refetch the graph. Debounce at 150 ms.
- **A 15-second safety poll** runs alongside, plus `/healthz` every 5 seconds.
- **All mutations shell out to `rig … --json`.**
  - The CLI is the documented contract.
  - It carries the prompt guards, identity stamping and fallback logic.
  - Each action maps one-to-one to a command the UI can show, as the design does with "rig send" and "rig queue handoff".
- **The HTTP API is internal.** Decode leniently (unknown keys ignored, most fields optional), gate on `/healthz` semver, and show an "untested daemon version" banner outside the tested range.

### State (Observation)
- `AppStore`: daemon status, the rig list, the selected rig.
- `RigStore` per rig: `graph`, `qitems`, `transitionsCache`, `seatStatus`, and derived `needsYou`, `chains`, `wires`.
- `SelectionStore`: `selectedQItemID`, `selectedSeatID`, and the terminals `focusedSeatID`, which is separate from selection as the design requires.
- `ActionStore`: in-flight commands and per-control errors.
- Derivations live in `RigDomain` as pure functions; views only bind.

### Actions to commands

| UI action | Command |
|---|---|
| Message a seat | `rig send <seat> <text> --json` |
| Queue task | `rig queue create --destination … --summary … --body-file -` |
| Hand off | `rig queue handoff <id> --to … --summary …`, then optionally `rig send` for "Also tell" |
| Block on | `rig queue block <id> --on … --wake-after` or `--wake-watchdog`, with `--summary` and `--evidence-ref` for human parks |
| Close | `rig queue update <id> --state done --closure-reason … [--closure-target …] --resolution …` |
| Nudge | `rig send` to the owner |
| Note only | `rig queue update <id> --note …` (the flag is inferred from the command's description; confirm it) |
| New deadline | `rig queue update --closure-required-at` |
| Allow once | `rig send <seat> --dangerously-interact --reason "OpenRig.app: allow once <cmd>" 1`, then `rig queue resolve <id> --decision "allow once: <cmd>"` if a human-gated HELD row exists |
| No, redirect | The option-3 keystroke plus the reason text, same path |

Bodies go over stdin, never through shell interpolation.

### Errors and offline
- No surface goes blank when the daemon is unreachable: the sidebar footer flips to "Daemon stopped" with a Start button (`rig daemon start`), data stays visible but dimmed with a "stale since" time, and action buttons disable.
- CLI non-zero exits show stderr inline on the control that issued them. No toasts, per the design.
- `rig send --verify` exit 1 means "unconfirmed", not "failed"; show it that way.

## 3. Terminal approach

### Recommendation
Use **SwiftTerm** as the only renderer, with exactly one live tmux client: the keyboard-focused tile. Every other tile is a read-only snapshot.

### Why not the alternatives
- **A `tmux attach` per tile.** With `window-size latest`, every small tile fights the existing 84x52 clients for pane size and reflows Claude Code for everyone. `-f ignore-size,read-only` avoids the resize but crops to the top-left, hiding the prompt at the bottom.
- **tmux control mode (`-CC`).** A control client is bound to one session and seats are one session each, so it needs N clients plus a hand-written protocol parser and screen reconstruction. That is the multiplexer this plan rules out.
- **libghostty.** Best rendering, but the embedding API is not a stable public surface and it needs a Zig toolchain in CI. Revisit behind the same protocol.
- **Daemon terminal WebSocket.** The cleanest protocol: no extra tmux clients, no geometry impact, shared broker. But it is off unless the web UI is enabled, and it is an internal contract built for xterm.js. Keep it as a second source and spike it in M3.

### Concretely
- `protocol TerminalSource` yields bytes and geometry and accepts input.
- **`TmuxSnapshotSource`** serves unfocused tiles.
  - It runs `tmux -S <socketPath> capture-pane -p -e -t <paneId>`, with pane size and cursor from `display-message -p`.
  - Captures for all tiles are batched into one tmux invocation per tick.
  - Cadence is 1 Hz, 4 Hz for attention tiles, and immediately on `seat.activity_changed`.
  - Output is fed into a non-interactive SwiftTerm `TerminalView` sized to the pane grid.
  - Small tiles show the bottom N rows, which matches the design's tail-of-pane tiles.
  - A tile whose last successful capture is older than 3 seconds shows "stale".
- **`TmuxAttachSource`** serves the focused tile. It is a SwiftTerm `LocalProcessTerminalView` running `tmux -S <socketPath> attach-session -t '=<seat>@<rig>'`.
  - In "Message · rig send" mode the view is not first responder; keys go to the composer.
  - In "Type into terminal" mode it becomes first responder and keys go straight to tmux.
  - Esc-to-reset, from the design, is handled by a local key monitor before SwiftTerm sees it.
- **Focus maps to one client.** Moving focus terminates the old pty, which detaches that client, and spawns one for the new tile. Clicking an answer button never moves focus.
- **Feasible counts.** One live client by design. Roughly 20 to 30 snapshot tiles is an estimate, not a measurement; benchmark in M3.

### Spike items for M3
- Whether the attached client should size the pane (plain tmux behaviour) or use `ignore-size` with font-fit.
- How to handle the tmux status row in the attached tile.
- Whether the daemon WebSocket source is good enough to replace the attach.

## 4. Canvas

### Rendering
- Seats and pods are real SwiftUI views; they hold buttons, menus and the permission control.
- They sit in one zoom and pan container (`scaleEffect` and `offset`, `MagnifyGesture`, scroll-wheel pan).
- All wires draw in a single SwiftUI `Canvas` beneath the nodes: `Path` strokes with `StrokeStyle(dash:)`.
- Wire chips ("q-0412", "q-0409 · blocked") are views positioned from router output.
- Node sizes are measured with `onGeometryChange` and fed to the layout engine, because node height varies with the permission card.

### Layout
The daemon gives no positions and the graph is small, so use a deterministic layered layout in `RigCanvasLayout` rather than a general graph library.
- Pod rank is the longest path over the pod-level `delegates_to` graph, with cycles broken by spec order.
- Pods are columns left to right; seats stack inside a pod in spec order.
- Each seat has one out port at the header's right edge and one in port at its left edge.

### Metro router
A pure function, `route(layout, requests) -> [Wire]`.
1. **Channels.** Build vertical channels in each gap between pod columns and at the outer margins, horizontal channels above, below and between pod rows, and a gutter inside each pod.
2. **Channel graph.** Vertices are channel intersections plus a stub vertex per port. Edges are channel segments that cross no inflated node rectangle.
3. **Path.** Run Dijkstra per request with cost equal to length plus a bend penalty of about 40 pt. Break ties deterministically.
4. **Bundling.** Requests from the same source port share a trunk: route in order of target y and discount segments already used by that source. This reproduces the fan-out at x=574 in the design prototype's routing script.
5. **Lanes.** Within a channel, segments from different sources get lane offsets by greedy interval colouring at 8 pt spacing, ordered to minimise crossings.
6. **Classes.** Each wire is one of needs-you, in-flight, next, past, delegates or observes.
   - Work wires reuse the spec edge's geometry for the same seat pair and draw above it.
   - A next-hop wire runs in the adjacent lane, as the dashed amber does beside the red in the mock.
   - A work hop with no spec edge is routed fresh.
7. **Finish.** Round corners with `min(10, l1/2, l2/2)`, as in the prototype's routing script. Put junction dots at trunk branches. Place the chip at the midpoint of the longest segment that clears all node rectangles.

### Router tests, written first
- Every segment is axis-aligned.
- No segment enters a node rectangle other than its endpoints.
- Same-source trunks coincide.
- Different-source parallel segments are at least one lane apart.
- Output is deterministic.
- A golden fixture for the denkeeper topology checks topology (bend counts and channel order) against the prototype's polylines.

## 5. Views

### Shell
- `NavigationSplitView` with a `List(selection:)` sidebar and `.badge(n)` on rigs.
- `.navigationTitle` is the rig name; `.navigationSubtitle` is "7 seats · 1 working · live".
- The toolbar holds a segmented `Picker` in `.principal`, with ⌘1/⌘2/⌘3 wired through `Commands`.
- The "Needs you" button opens an anchored popover that reuses the strip's row view.
- "Queue task" is `.glassProminent` and opens a popover with the seat prefilled from selection.
- The right panel is the native `.inspector`.
- Glass stays on chrome only. Cards, columns and tiles are opaque content.
- Target macOS 26; gate anything from 27.

### Canvas view
- Pod groups, seat nodes with state line, qitem line and an inline permission card, the legend, zoom controls and a minimap.
- The inspector has Queue, Transcript and Spec tabs.
  - Queue lists Needs you, Owned and Delegated cards.
  - Transcript reads `/api/transcripts`.
  - Spec is read-only in v1.
- A composer at the bottom issues `rig send`.

### Queue board
- Filter row: Active or Today, seat, overdue, and `.searchable`.
- Needs-you strip, collapsing into the toolbar popover below 720 pt.
- Four columns. Done splits into "Closed" and "Handed off", the latter with successor links.
- Blocked cards have two variants: on-you and held-on-qitem.
- The inspector shows owner, from, close-by, and the chain of record.
- Hand off, Block on and Close are one `ActionPanel` enum state rendered in place under the action row.
  - The commit button is named ("Hand off to orch-lead") and disabled until required fields are filled.
  - The mid-turn warning is driven by `agentActivity.state`.
  - Hand-off targets without a `delegates_to` edge are disabled.

### Chain of record, written test-first
- Normalise both handoff encodings into one "handed off" status.
- Index by `handedOffFrom`; walk back through `chainOfRecord` and forward through successors.
- Tests cover a missing ancestor outside the limit window, a branch, a cycle guard, and both encodings, using fixtures recorded from the real daemon.

### Terminals
- An adaptive grid: attention and focused seats get large tiles, the rest small.
- Tiles do not reorder while one has focus.
- The attention border is red; the focus ring is a separate white outer ring.
- The header shows a qitem chip with the selection ring.
- The answer bar grows upward for "No, redirect…".

### Permission control
One `PermissionControl` view (Allow once · No, redirect… · ⌄) used on the canvas node, the strip, the popover and the answer bar.
- It binds to a `PromptInstance`: seat, command and the observed-at stamp.
- It re-reads `permission_stop` immediately before sending, and disables with "prompt changed · view terminal" on a mismatch.
- "Always allow…" under ⌄ is deferred; see open question 5.

## 6. Milestones

| Milestone | Scope | Accepted when | Tests |
|---|---|---|---|
| M0 Scaffold | Repo, package, CI, daemon discovery | The app launches and shows daemon status and the rig list | Integration: decode live `/api/ps`, `/healthz` and graph, skipped when no daemon. Decoder tests on recorded payloads |
| M1 Canvas, read-only | Layout, router, spec edges, seat states, SSE refresh, seat inspector | denkeeper renders with 3 pods, 7 seats and 10 edges, and updates within 1 s of an event | Router and layout suites. Integration: the SSE stream parses and resumes with `Last-Event-ID` |
| M2 Queue board, read-only | Columns, chains, work wires, shared selection | Selecting a qitem rings it in all three views; the chain matches `rig queue show` | Chain and selection-rule tests. Integration: reconstruct a real chain and compare with the daemon's `chainOfRecord` |
| M3 Terminals | Snapshot tiles, focused attach, Type mode | Seven tiles live with one tmux client; focus moves leave exactly one client | Integration against a throwaway tmux server on a private socket: captured bytes render, and the client count is 1 |
| M4 Actions | Send, create, hand off, block, close, nudge, note | Each action's result appears through SSE without a manual refresh | Argv-builder tests. Opt-in integration (`just test-live`) against a scratch rig |
| M5 Permission and Needs you | The control, strip, popover, resolve | Allow once answers a real prompt and the item leaves Needs you | Prompt-instance staleness tests. Manual script against a live prompt |
| M6 Hardening | Offline states, Reduce Transparency, narrow widths, version gate | The app degrades without blank screens when the daemon stops | Integration: daemon-down handling against a closed port |

## 7. Scaffolding

### Project
- XcodeGen is installed at `/opt/homebrew/bin/xcodegen`. Use a `project.yml` that generates an uncommitted `.xcodeproj` for the app target, plus the local SwiftPM package for all logic so `swift test` runs without Xcode UI.
- `xcode-select` points at CommandLineTools, so `xcodebuild` fails today. `/Applications/Xcode.app` exists; the justfile should export `DEVELOPER_DIR`.
- The project directory is in iCloud Drive. Keep build output out of it with `-derivedDataPath ~/Library/Developer/…` and a `.build` path outside the tree or a `.nosync` directory.

### Dependencies
Pin exact versions in `Package.swift` and commit `Package.resolved`. Current version numbers were not looked up; resolve them at scaffold time.
- **SwiftTerm** (migueldeicaza): terminal rendering.
- **swift-collections** (Apple): `Heap` for Dijkstra, `OrderedDictionary`.
- **swift-subprocess** (swiftlang): async process execution with stdin. Fall back to Foundation `Process` if it is still pre-1.0 churn.
- **An SSE client**, such as LaunchDarkly `swift-eventsource`, for reconnect and `Last-Event-ID`. Confirm it is maintained.
- **System frameworks for the rest**: `URLSession`, `JSONDecoder`, and `DispatchSource` to watch `~/.openrig/daemon.json`. No file-watching or graph-layout library is needed.

### justfile
`gen`, `build`, `test` (package tests), `test-live` (opt-in, mutating; added in M4), `lint`, `format`, `run`, `record-fixtures`, `clean`. Lint uses `swift format` from the toolchain; SwiftLint was dropped to avoid an extra install.

### CI
- GitHub Actions on a macOS 26 runner with Xcode 26 selected.
- Steps: install just and xcodegen; `just lint`; `just test`; `just build` ad-hoc signed.
- Daemon-dependent tests skip themselves through a Swift Testing condition trait. The tmux integration tests run in CI after `brew install tmux`.
- README carries build-status and Apache-2.0 badges, no coverage badge. `LICENSE` is Apache-2.0.

### Signing and sandbox
- **App Sandbox off.** The app execs `/opt/homebrew/bin/rig` and `tmux`, opens the tmux unix socket, and reads `~/.openrig/daemon.json`.
- **Hardened runtime on.** Ad-hoc signing for dev; Developer ID and notarisation later.
- **Loopback HTTP.** Set `NSAllowsLocalNetworking` for `http://127.0.0.1`.
- **PATH.** GUI apps do not inherit the shell PATH. Resolve `rig` and `tmux` from known locations plus a setting, and pass a PATH that includes Homebrew so the Node shebang resolves.
- **Secrets.** Never read `~/.openrig/activity-endpoint.json` or other token files for display or logging; it holds a plaintext bearer next to `baseUrl`.

## 8. Risks and open questions, ranked

1. **Who is "you"? Decided: act as `operator-human@kernel`.** The app stamps that seat as the actor on every CLI action (via `OPENRIG_SESSION_NAME`), so history reads "closed by operator-human". Verify in M4 that every write route accepts it.
2. **Driving permission prompts.** `--dangerously-interact` is the only sanctioned path, and it is audited and guarded. The option numbering ("1", "3") is specific to Claude Code and could change. `permission_stop` is Claude-only and no live one was observed. Codex seats may need a different mechanism or be left out of v1.
3. **Internal HTTP API drift.** Mitigated by the version gate, lenient decoding and live contract tests. The alternative is CLI-only reads at a latency cost.
4. **Pane geometry ownership.** Should the app's focused client resize a seat that Herdr or another terminal is also showing?
5. **"Always allow in this project…"** Which command writes that rule (`rig seat set-permissions` or `rig policy`) was not traced. Proposed: defer past v1. *Resolved after M6: no rig command; it is the prompt's own option 2.*
6. **Next-hop wire.** There is no data source. Options are to drop it in v1, derive it from `rig workflow` for workflow-bound items, or ask upstream for a field. *Resolved after M6: derived from `rig workflow` instances.*
7. **Short qitem ids.** The design's `q-0409` needs a display rule, for example the last 4 hex characters with the full id on hover.
8. **Daemon terminal WebSocket.** Enable `ui.enabled`, or ask upstream to decouple it? It would remove the attach client entirely.
9. **Multi-host (`--host`), Stream, Watchdog, Chatroom and Library sidebar items.** Proposed as navigation stubs in v1.

## Files to create first
- `OpenRigKit/Sources/RigCanvasLayout/MetroRouter.swift`
- `OpenRigKit/Sources/RigDomain/ChainOfRecord.swift`
- `OpenRigKit/Sources/RigClient/DaemonHTTP.swift`
- `OpenRigKit/Sources/RigTerminal/TerminalSource.swift`

## References
- Daemon routes: `/opt/homebrew/Cellar/openrig/0.7.11/libexec/lib/node_modules/@openrig/cli/daemon/dist/server.js`, plus `routes/queue.js`, `routes/events.js`, `routes/terminal-ws.js`.
- Design: Paper file "OpenRig — Canvas prototype", page "Starter · Rig canvas" (https://app.paper.design/file/01M7P253KBMTNSBCBX3V1CRWRB/p-2-0), including the "Inline action states" board.

## Implementation notes

Deviations and discoveries, by milestone. Each line is something the plan above doesn't say.

### M0
- Lint is `swift format` from the toolchain, not SwiftLint.

### M1
- **SSE client is hand-written** (`RigClient/EventStream.swift`, about 150 lines) instead of a library. It splits raw bytes because `AsyncBytes.lines` drops the blank lines that end SSE messages.
- **URLSession withholds the response until body bytes arrive**, and a quiet daemon sends none. Each connection asks for one already-seen event (`replay=1`, or `Last-Event-ID` one back) so "live" shows at once.
- **Queue and seat-activity events carry no `rigId`.** The app uses the global stream and filters by event type.
- **`can_observe` points from observer to observed.** Observe wires and layout ranking reverse it.
- `RigDomain` depends on `RigCanvasLayout` for the graph-to-layout adapter.
- Router costs added beyond the plan: vertical runs outside channels cost 3x, and crossing a pod that is neither end's costs 2.5x. Without them, trunks hug pod borders.
- Fixtures moved to a shared `RigFixtures` test-support target.

### M2
- **`handedOffTo` is a session, not a qitem id.** Successors are found by indexing rows on `handedOffFrom`. `chainOfRecord` is ancestor ids, oldest first, ending with the direct predecessor.
- **Needs you (until M5)** = blocked on a ref that isn't a qitem (for example `external:person-decision-pr602`), or a row with `humanQuestions`. Permission prompts join it in M5.
- **Next-hop wire dropped for v1** (risk 6): no data source. Past hops draw for the selected item's chain. (Restored after M6 for workflow packets; see below.)
- **Short ids**: `q-` plus the last four hex characters (risk 7), full id on hover.
- Queue fixtures replace summaries, bodies and resolutions with placeholder text; the rows are agents' free text.
- The board's columns size to the width the floating inspector leaves, 220 pt minimum, then scroll sideways.
- Work wires were not seen live: neither local rig had active qitems during M2. Unit tests cover their geometry and kinds.

### M3
- **SwiftTerm 1.99.2 ships a build-tool plugin** (generated build info). Xcode asks for "Trust & Enable" once per machine; CI passes `-skipPackagePluginValidation` (`just build -skipPackagePluginValidation`). 1.18.0, the last version without the plugin, needs the separately downloaded Metal toolchain.
- **The focused client attaches with `-f ignore-size`** at the pane's size, plus one row when the status bar is on. It never resizes panes that other terminals show (risk 4, decided). Tiles pick a font size that fits the pane's columns instead of scaling the image.
- **Attach output is buffered** (256 KB) and replayed to a late subscriber: tmux paints the whole screen once on attach, usually before the view binds.
- **Small tiles show the tail of the pane** ending at the last line with text or the cursor, so blank rows at the bottom don't hide the prompt.
- **Esc in Type mode is swallowed** and returns to Message mode, so a stray Esc can't interrupt an agent mid-turn.
- SwiftTerm's view takes clicks itself; unfocused tiles put a transparent Button over it to take focus (also reachable by VoiceOver).
- Verified live: focusing a tile adds exactly one tmux client, moving focus keeps the total, leaving the view removes it.
- The daemon's terminal WebSocket (spike item) was not tried; snapshots plus one attach met the bar.

### M4
- **Identity verified**: `rig queue whoami` and every write accept `OPENRIG_SESSION_NAME=operator-human@kernel` from outside a seat; transitions record it as the actor (risk 1, closed).
- **Queue task always nudges** the destination (the CLI default). Live tests use `--no-nudge`, because a nudge to the human seat types into its terminal.
- **Hand-off targets** are limited to the owner's `delegates_to` seats, as planned. "Also tell" runs `rig send` only after the handoff succeeds.
- **Nudge opens an editable message** rather than sending at once; it types into an agent's pane.
- **`just test-live`** (opt-in, `OPENRIG_LIVE_WRITES=1`) creates one self-addressed qitem, notes it, closes it as canceled, and requires each step on the event stream within 1 s.
- Verified in the app: a note and a close made from the inspector reached the daemon as `operator-human@kernel`, and the board updated through the event stream within about a second. Handoff, block, nudge and send were not run live (they would touch agents); argv tests cover them.
- `Resolve` (answering a human-gated HELD row) moves to M5 with the permission control.

### M5
- **The daemon withholds the command** (`"command": "Bash: details withheld"`). The control reads the prompt off the seat's pane (`PromptScreen`, tested on a live capture) to show the title, the agent's reason and the full command.
- **Answers pick options by label, never by position.** Allow once sends the number of the option reading exactly "Yes"; decline sends the option reading "No". On Claude Code's current menu, option 3 is "Yes, and switch to auto mode", so the planned "3 for redirect" would have changed the seat's mode. With no such label on screen, the button disables.
- **Esc can't be sent**: as a character it reaches the prompt as the start of an escape sequence and does nothing.
- **A decline sends no hook**, so the daemon keeps reporting the prompt and `rig send` refuses. The app waits for the pane to clear, runs `rig seat clear-attention --reason …` if the daemon still holds the prompt, then sends the redirect. Needs you lists a prompt only while the pane still shows one.
- **Before answering**, the control re-reads both the daemon's `permission_stop` and the pane; any difference shows "Prompt changed · View terminal" and sends nothing.
- `rig send` exit 1 counts as "sent, not confirmed" only when its JSON says `sent: true`; a refusal also exits 1.
- Verified live on a throwaway rig (`rig create openrig-apptest`): Allow once answered a real prompt and the seat left Needs you; Decline + redirect cancelled a prompt and delivered the message. `rig queue resolve` for a linked held row was not exercised (no such row); see "After M6".

### M6
- **Daemon down**: the last data stays on screen, dimmed, under a banner ("Daemon stopped. Showing data from 4:43 pm, read-only.") with Start daemon (`rig daemon start`) and Retry; the sidebar footer has the same Start button. Writes are refused while offline, and their buttons disable. Verified by pointing the app at a local proxy (`OPENRIG_URL`) and stopping and restarting the proxy; the real daemon was never stopped.
- **Version gate**: rig 0.7.x is tested; any other minor version shows an "untested" banner (`DaemonHealth.compatibility`, tested).
- **Reduce Transparency**: the floating legend uses an opaque surface instead of glass.
- **Narrow windows (to the 820 pt minimum)** exposed two layout feedback loops that crashed AppKit: the canvas refit when scroll bars appeared or disappeared (now ignores changes under 20 pt and fits with a 4% margin), and the board's fixed-size filter row setting the detail column's minimum width (now scrolls). Both were reproduced and verified with scripted resizes across all three views.
- At the minimum width the toolbar moves Needs you, Queue task and the inspector button into its overflow menu. `.visibilityPriority` (macOS 27) could keep Needs you visible.
- **Lesson**: pipe gate commands with `set -o pipefail`; a `| tail` hid a lint failure in the M5 commit.

### After M6
- **Down seats.** Killing a test seat's tmux session leaves `status: running` until the daemon's reconciler marks it `detached`, but the activity reason turns `session_missing` at once (recorded as `graph-lost.json`). `presence(_:)` reads both, plus `exited` and `failed`. A lost or failed seat is drawn with an orange ✕ and a dashed border, its work line says "stalled", its composer disables, and it joins Needs you after prompts. The app doesn't restore seats: `rig up <rig> --existing` restores the whole rig, so the inspector offers its `--plan` preview to copy.
- **Two prompts at once.** Each seat keeps its own control. Needs you lists prompts oldest first, and a prompting seat's terminal tile is large with the red border even before the daemon flags attention.
- **Board width bug.** The board subtracted the split view's safe-area insets from a width that already excluded the sidebar and inspector, so at 1440 pt it measured 460 pt: the Needs-you strip never showed and columns stayed at their minimum. Fixed.
- **Wide panes.** A 170-column pane at the 6 pt minimum font is wider than a tile column; the tile now clips it instead of widening and pushing the grid under the sidebar.
- **DEBUG launch hooks** for screenshots without clicking (a locked screen): `OPENRIG_DEBUG_OPEN=<rig>/<view>/<session>`, `OPENRIG_DEBUG_SIZE=<w>x<h>`, and `OPENRIG_DEBUG_PROMPT` now takes several `;`-separated prompts.
- **Remember (was "Always allow…").** No rig command writes the rule: it is the prompt's own option 2, which Claude Code words several ways (all seen live). "Yes, and allow access to /tmp and mkdir … commands" wrote `Bash(mkdir -p …)` and `Read(//tmp/**)` to the project's `.claude/settings.local.json`; "Yes, allow reading from … from this project" saved nothing on disk, so it lasts the session. The ⌄ menu item is labelled with the option's own words and picks it by label like Yes and No; a mode switch ("switch to auto mode") never matches.
- **Restoring a lost seat.** `rig up <rig> --existing` reported `fully_restored` for a seat killed before its first turn, but Claude exited at once ("No conversation found") and the seat sat at a shell (`generation_mismatch`). The inspector only offers the `--plan` preview to copy.
- **Next-hop wire, for workflow packets.** `GET /api/workflow/list` returns each instance's frontier packets (qitem and step) and the spec it started from. `nextHop(for:in:)` ports the daemon's own rule for a normal close (`resolveNextStep`, `resolveDefaultOwner`): `forbid` stops, `suggested_roles` jump, `require` stops, else declaration order; the owner is the role's first preferred target, or the first matching a pinned harness. A role with no targets is resolved live by the daemon, so no wire. The selected packet gets a dashed amber wire from its owner to the next owner with a "next: <step>" chip, and the inspector a Next row. Verified on a two-seat test rig (a Claude seat and a terminal seat) with a two-step workflow. Non-workflow items still have no next hop.
- **Resolve, live.** A row blocked on `external:…` shows in Needs you, and its inspector now leads with a Resolve panel (decision text, then `rig queue resolve --decision`). On the test rig the resolve went through as `operator-human@kernel` with no bearer, the row moved to in progress through the event stream and left Needs you, and the owner was nudged and closed it. Gap 8 is closed. (The prompt flow resolves a linked held row with the same action.)
- **Block sends `--note`, not `--summary`.** rig 0.7.11 refuses `--summary` on a block (`summary_evidence_not_persistable`) unless the blocker is a registered human seat; `operator-human@kernel` isn't one, so every summary the Block panel sent failed. The decision owed now goes in the transition note.
- **Queue rows.** `canceled` (an aborted workflow's open packets) is closed, not in progress. Rows with no summary (workflow packets) show their body's first line.
