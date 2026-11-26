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
7. **"Asked you" source: closed.** Agents ask the person with a queue row addressed to them (see "Acting as a person" below). `humanQuestions` is `[{id, question, options: [{id, label}]}]`; `GET /api/attention` is the daemon's own Feed of the same rows.
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
- **Push comes from `/api/events`.** Events are invalidation signals, not state: on `queue.*` refetch the queue list, on `seat.activity_changed` or `agent.activity` refetch the graph. A refresh starts 250 ms after the first event and at most once every 2 s (see "Refresh load").
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
- **Sheen on in-flight wires (2026-11-22).** Both ends of a wire looked alike and bundles share trunks, so a busy canvas didn't show which way work moved. A soft band of light now drifts from sender to receiver over a slightly dimmed wire, once every 12 s on every wire whatever its length. It was picked over a pulse, marching dashes, chevrons and beads in the motion study (https://claude.ai/artifact/Rgcyb3BeX7GLncw7S6tdeB); dashes already mean observes and next hop. Timing lives in `Sheen` (RigCanvasLayout, tested). The bands are `CAShapeLayer`s with keyframed stroke ends, run by Core Animation: a SwiftUI `TimelineView` cost about 15% CPU, mostly a window layout pass every frame. None with Reduce Motion; no dimming with Increase Contrast.
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
4. **Bundling.** Requests in one bundle (same kind, sharing a source or a target) share a trunk: route in order of target y and discount segments already used by that bundle. This reproduces the fan-out at x=574 in the design prototype's routing script.
5. **Lanes.** Within a channel, segments from different sources get lane offsets by greedy interval colouring at 8 pt spacing, ordered to minimise crossings.
6. **Classes.** Each wire is one of needs-you, in-flight, next, past, delegates or observes.
   - Work wires reuse the spec edge's geometry for the same seat pair and draw above it.
   - A next-hop wire runs in the adjacent lane, as the dashed amber does beside the red in the mock.
   - A work hop with no spec edge is routed fresh.
7. **Finish.** Round corners with `min(10, l1/2, l2/2)`, as in the prototype's routing script. Put junction dots at trunk branches: 4.5 pt, in the colour of the most prominent wire through them, and only one where several sit within a lane of each other (`thinned`). "Observes" wires draw faint and thin at rest and at full strength while either end's seat is hovered or selected, so watch lines stay context, not flow. Then place the labels (`placeLabels`): each at its drawn size, clear of seat cards and of each other, touching its wire. A label clear at the midpoint of its wire's longest clear run stays there. Otherwise it goes centred on the wire where that fits, else beside it with one edge on the wire. Open canvas beats a pod's frame, and a pod's frame beats its title. The bounds grow right and down to hold a label past the last column.

### Router tests, written first
- Every segment is axis-aligned.
- No segment enters a node rectangle other than its endpoints.
- Trunks within a bundle coincide. A bundle is wires of one kind joined by a shared source (fan-out) or target (fan-in), so two builders watching the same reviewers draw as one watch line. A group bundles only if every source reaches every target; otherwise one trunk would suggest links that don't exist, and each source keeps its own fan-out.
- Bundles into one seat never share a final run: the most prominent kind keeps the port and each other bundle enters a lane below it (`staggerInPorts`).
- Branches turn square at junctions, so the dot sits on the corner; other corners stay rounded.
- Different-bundle parallel segments are at least one lane apart, centred on the line and ordered to cross each other's turns least (`assignLanes`).
- Two wires whose ends interleave along a shared line cross whatever their lane order. After lanes, a bundle that crosses another is re-routed with the crossed wire's grid points made expensive, and kept if it removes crossings for at most `detourPerCrossing` (480 pt, bends at the bend penalty) each. Work bundles are tried before spec bundles. Watch lines draw faint and don't count.
- Output is deterministic.
- A golden fixture for the denkeeper topology checks topology (bend counts and channel order) against the prototype's polylines.
- Labels, on denkeeper with a work wire for every ordered pair of seats, 50 and 110 pt wide, and each seat in turn 220 pt tall: each label clears the cards by 4 pt (the selection ring), touches its wire and sits inside the bounds. Labels sharing a wire, or on a fan-out, don't overlap. A clear label stays put. Input order doesn't change the result.

## 5. Views

### Shell
- `NavigationSplitView` with a `List(selection:)` sidebar and `.badge(n)` on rigs.
- `.navigationTitle` is the rig name; `.navigationSubtitle` is "7 seats · 1 working · live".
- The toolbar holds a segmented `Picker` in `.principal`, with ⌘1/⌘2/⌘3 wired through `Commands`.
- The "Needs you" button opens an anchored popover that reuses the strip's row view.
- "Queue task" is `.glassProminent` and opens a popover with the seat prefilled from selection.
- The right panel is the native `.inspector`.
- Glass stays on chrome only. Cards, columns and tiles are opaque content.
- Target macOS 27.

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
- GitHub Actions on the `xcode-27` runner image (macOS 27, its default Xcode 27). Xcode 26.6 crashes compiling the app.
- Steps: install just and xcodegen; `just lint`; `just test`; `just build` ad-hoc signed.
- Daemon-dependent tests skip themselves through a Swift Testing condition trait. The tmux integration tests run in CI after `brew install tmux`.
- README carries build-status and Apache-2.0 badges, no coverage badge. `LICENSE` is Apache-2.0.

### Signing and sandbox
- **App Sandbox off.** The app execs `/opt/homebrew/bin/rig` and `tmux`, opens the tmux unix socket, and reads `~/.openrig/daemon.json`.
- **Hardened runtime on.** Ad-hoc signing for dev; Developer ID and notarisation later.
- **Canary (2026-11-23).** `just install` builds `/Applications/OpenRig Canary.app` (`dev.openrig.OpenRig.canary`, yellow icon), so a local build can run beside the public release and look different. It has its own defaults, login item and notification permission; the Keychain token is shared, because the service name is fixed.
- **Loopback HTTP.** Set `NSAllowsLocalNetworking` for `http://127.0.0.1`.
- **PATH.** GUI apps do not inherit the shell PATH. Resolve `rig` and `tmux` from known locations plus a setting, and pass a PATH that includes Homebrew so the Node shebang resolves.
- **Secrets.** Never read `~/.openrig/activity-endpoint.json` or other token files for display or logging; it holds a plaintext bearer next to `baseUrl`.

## 8. Risks and open questions, ranked

1. **Who is "you"? Revised: act as a person, never as `operator-human@kernel`.** That seat is the TUI's own pane ("not a human inbox"), so an agent replying to it typed into the TUI and the message was lost. The app now acts as the gateway's default person (`<id>@external`) and falls back to `human@host`, the unnamed person, when nobody is registered. A message from either address tells the agent to reply with a queue row. Unregistered, `human@host` has no wake route, so the daemon's stuck sweep pings the sender about every reply; registering a person (`rig gateway human add <id> --default`) avoids that. The actor is set via `OPENRIG_SESSION_NAME`, read from `GET /api/gateway/participants`, and changes without a relaunch.
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
- **`just test-live`** (opt-in, `OPENRIG_LIVE_WRITES=1`) creates one self-addressed qitem, notes it, closes it as canceled, and requires each step on the event stream within 1 s. It also runs the read-only chain check, `LiveChainTests` (`OPENRIG_LIVE_READS=1`), which left `just test` on 2026-11-24 because it timed out against a busy daemon.
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
- At the minimum width the toolbar moves Needs you, Queue task and the inspector button into its overflow menu. `.visibilityPriority` (macOS 27) could keep Needs you visible. (Fixed after M6; see below.)
- **Lesson**: pipe gate commands with `set -o pipefail`; a `| tail` hid a lint failure in the M5 commit.

### After M6
- **Down seats.** Killing a test seat's tmux session leaves `status: running` until the daemon's reconciler marks it `detached`, but the activity reason turns `session_missing` at once (recorded as `graph-lost.json`). `presence(_:)` reads both, plus `exited` and `failed`. A lost or failed seat is drawn with an orange ✕ and a dashed border, its work line says "stalled", its composer disables, and it joins Needs you after prompts. The app doesn't restore seats: `rig up <rig> --existing` restores the whole rig, so the inspector offers its `--plan` preview to copy.
- **Two prompts at once.** Each seat keeps its own control. Needs you lists prompts oldest first, and a prompting seat's terminal tile is large with the red border even before the daemon flags attention.
- **Board width bug.** The board subtracted the split view's safe-area insets from a width that already excluded the sidebar and inspector, so at 1440 pt it measured 460 pt: the Needs-you strip never showed and columns stayed at their minimum. Fixed.
- **Canvas band.** A rig smaller than the window sat centred with bare background above it, under a hairline, which read as a separate panel. The dot grid now sits behind a frame at least the visible size, so it covers the whole canvas, and a tap anywhere on it clears the selection. Checked through 820×520 and back with `OPENRIG_DEBUG_SIZE`: no refit loop.
- **Wide panes.** A 170-column pane at the 6 pt minimum font is wider than a tile column; the tile now clips it instead of widening and pushing the grid under the sidebar.
- **DEBUG launch hooks** for screenshots without clicking (a locked screen): `OPENRIG_DEBUG_OPEN=<rig>/<view>/<session>`, `OPENRIG_DEBUG_SIZE=<w>x<h>`, and `OPENRIG_DEBUG_PROMPT` now takes several `;`-separated prompts. Later: `OPENRIG_DEBUG_SETTINGS=<tab>`, `OPENRIG_DEBUG_BADGE=<file>`, `OPENRIG_DEBUG_BANNERS=<file>`, `OPENRIG_DEBUG_PROMPT_AFTER=<seconds>` and `OPENRIG_DEBUG_SHOW=<seconds>|<rig>|<session>` `OPENRIG_DEBUG_SCROLL=<points>` (scrolls the Terminals grid once), `OPENRIG_DEBUG_WIDTHS=<file>` (one line per pane-width measurement), and `OPENRIG_DEBUG_AX=<file>[,<tabs>]`, which writes the main window's accessibility tree and Tab stops from inside the app. macOS hides other apps' windows from AX while the screen is locked; run any AX client once first (e.g. a tree query) so SwiftUI builds its tree. `OPENRIG_DEBUG_ROW=<file>` adds made-up rows to the queue (see "Images on queue rows").
- **Remember (was "Always allow…").** No rig command writes the rule: it is the prompt's own option 2, which Claude Code words several ways (all seen live). "Yes, and allow access to /tmp and mkdir … commands" wrote `Bash(mkdir -p …)` and `Read(//tmp/**)` to the project's `.claude/settings.local.json`; "Yes, allow reading from … from this project" saved nothing on disk, so it lasts the session. The ⌄ menu item is labelled with the option's own words and picks it by label like Yes and No; a mode switch ("switch to auto mode") never matches.
- **Restoring a lost seat.** `rig up <rig> --existing` reported `fully_restored` for a seat killed before its first turn, but Claude exited at once ("No conversation found") and the seat sat at a shell (`generation_mismatch`). The inspector only offers the `--plan` preview to copy.
- **Next-hop wire, for workflow packets.** `GET /api/workflow/list` returns each instance's frontier packets (qitem and step) and the spec it started from. `nextHop(for:in:)` ports the daemon's own rule for a normal close (`resolveNextStep`, `resolveDefaultOwner`): `forbid` stops, `suggested_roles` jump, `require` stops, else declaration order; the owner is the role's first preferred target, or the first matching a pinned harness. A role with no targets is resolved live by the daemon, so no wire. The selected packet gets a dashed amber wire from its owner to the next owner with a "next: <step>" chip, and the inspector a Next row. Verified on a two-seat test rig (a Claude seat and a terminal seat) with a two-step workflow. Non-workflow items still have no next hop.
- **Resolve, live.** A row blocked on `external:…` shows in Needs you, and its inspector now leads with a Resolve panel (decision text, then `rig queue resolve --decision`). On the test rig the resolve went through as `operator-human@kernel` with no bearer, the row moved to in progress through the event stream and left Needs you, and the owner was nudged and closed it. Gap 8 is closed. (The prompt flow resolves a linked held row with the same action.)
- **Block sends `--note`, not `--summary`.** rig 0.7.11 refuses `--summary` on a block (`summary_evidence_not_persistable`) unless the blocker is a registered human seat; `operator-human@kernel` isn't one, so every summary the Block panel sent failed. The decision owed now goes in the transition note.
- **Queue rows.** `canceled` (an aborted workflow's open packets) is closed, not in progress. Rows with no summary (workflow packets) show their body's first line.
- **Needs you at narrow widths.** The toolbar is split by column: the view switcher, Needs you and Queue task sit over the detail column and end at the inspector's edge, and the inspector toggle sits over the inspector. They are icons at every width (labels that came and went with the width re-made each item with a fade). Below a 400 pt detail column the rig title leaves the toolbar and the switcher moves leading; mid-drag that change only happens while narrowing. Needs you and Queue task carry `.visibilityPriority(.high)` (macOS 26.1+), and so does the switcher except when tight, so it is the first to overflow if a wider sidebar or inspector leaves too little room. At the 820 pt minimum every item fits in all three views. The queue's search sits in the board's filter row instead (`BoardSearchField`): `.searchable` put it over the inspector, and neither `DefaultToolbarItem(kind: .search)` nor declaring it inside `.searchable` moved it. It overlays the row's trailing edge so the filters scroll under it when narrow, and the row has no ideal width of its own: the split view sizes the detail column toward its content's ideal width on a resize, and a wide row squeezed the sidebar below its minimum. ⌘F is View › Search Queue, which switches to the board and focuses the field; Escape clears it.
- **Wire labels, 2026-11-23.** A label could sit half under a seat card: placement checked only the label's centre. It happened on a same-pod wire running down the pod's inner edge, 16 pt from the card, which the router picks when other wires fill the column channel. Such a label now hangs beside its wire, over the pod's border (`design/ui/10-wire-labels/`, option A). Labels draw above cards but below a prompt card, whose buttons stay on top. Each chip's size comes from its text before it draws, so it is placed once, with no measure-then-move. Chips cap at 120 pt and cut long text in the middle ("next: review-code-and-ui" is 161 pt): wider, a label beside a wire has no clear spot in the 112 pt column gap. Label growth widens the canvas but doesn't refit it; only seat layout does.

### Terminals, reviewed against the mock
- **Grid fits the window.** Prompts (oldest first), needs-you and working seats share the top rows; idle seats sit in fixed-height rows. Columns come from width (460 pt large, 230 pt small), not a fixed 3 + 4, since panes are 84 or 170 columns wide. Focus freezes the order; a focused small tile moves up and leaves a placeholder, and a new prompt still gets a large tile.
- **Tiles show the transcript.** Tails end above Claude Code's input box (`PaneSnapshot.transcriptEnd`), at a font fitted to the pane width with an 8.5 pt floor; wider panes clip on the right.
- **Focused tile.** Message mode shows the snapshot tail; Type mode (second click, or ⌘T) shows the live client sized to the tile, with a tmux `refresh-client` after each resize. A live client positioned partly outside its clip draws nothing in SwiftTerm, so it is never offset. Type mode (reworked after a UX and UI review): the typing tile is as tall as its pane needs at the width-fit size, under a strip of the other seats (a chip turns coral when one needs you; clicking it focuses that seat). The client shows the whole pane when it fits at the smallest tile text or larger, else the width-fit size and the rows that fit, panned to where the person types. tmux follows only a visible cursor, and Claude Code hides its own, so a short client showed the pane's top and hid the input; `PaneSnapshot.panOffset` pans to the bottom when the cursor is there, else to the cursor, and the header says how many rows are above. Typing pauses when the typed-into seat raises a permission prompt (from the pane within a second, or the daemon), so Enter can't answer it; ⌘T afterwards is deliberate. Cell metrics follow SwiftTerm's rounding on the view's own display (width to the nearest pixel, height up to a whole point), a font change re-sets the grid and repaints the client, the keyboard is taken only as Type mode starts, and mouse reporting is off so a scroll can't put the shared pane in tmux copy mode. With it off, SwiftTerm turned the wheel into arrow keys on the client's alternate screen, which scrolled Claude Code's input history; a scroll up now shows the pane's history instead (`capture-pane -S -`, a read-only copy at the client's size, from tmux's `history-limit`, so it covers time the app was closed). Scrolling past the bottom or any key goes back to the live client; a pane on the alternate screen (vim, less) keeps the arrow keys. A focused tile in Message mode scrolls back the same way. `OPENRIG_DEBUG_OPEN=<rig>/terminals/<session>[/typing]/history` opens it. The switch into and out of Type mode is a short crossfade (none with Reduce Motion), not a resize, because tiles host live clients. Done stops typing, and the grid comes back scrolled to where it was. A pane wider than its tile at the smallest tile text fades out at the right edge instead of ending mid-glyph. The pane itself is never resized (`ignore-size`).
- **Fixed on the way:** the blank focused tile (one subscriber per `AttachSession`; SwiftUI's replacement view was unsubscribed by the old one), and attention tints drawing dark in light mode.
- **Keys:** ⌘] / ⌘[ move focus, ⌘T toggles Type mode, Esc leaves Type mode and then releases focus. No key answers a prompt.

### Acting as a person
- **Lost replies.** A message from the app reached orch-lead as `From: operator-human@kernel` with the hint `↩ Reply: rig send operator-human@kernel`. That seat is the TUI's pane, so the reply was typed into the TUI ("unknown command") and lost, while rig reported it delivered. The daemon keeps every message in the sender's outbox (`GET /api/queue/outbox/list?rig=`).
- **Identity.** The app now acts as the gateway's default person (`rig gateway human add <id> --default`, here `artem@external`), else `human@host`. From either, the envelope's hint becomes `rig queue create --destination <you> …`, so replies are queue rows. Unregistered, `human@host` has no wake route and the daemon's stuck sweep files an `undelivered-wake` row back to the sender within minutes; a registered person is `gateway-owned` and isn't swept.
- **Rows to a person need `--evidence-ref`** (`human_route_fields_required`); `just test-live` now passes one.
- **Needs you** adds live rows addressed to the person (or to `human@host`/`human@kernel`): decisions with held rows, FYIs (`humanIntent: update`) last. The badge counts decisions only; FYIs alone show a grey count.
- **Answering.** Approve and Deny close the row (`no-follow-on` / `denied`, note as resolution). Closing doesn't tell the asker, and neither does the TUI's own `approve` (`ownerNotificationLevel: RECORD`), so the app sends the answer with `rig send` first, then closes; a failed send leaves the row open. FYIs get Got it (close) and Reply. The flow lives in `Answer` (RigClient), unit-tested for order and retries: a retry after a failed close doesn't resend the same answer, a changed answer goes out marked "Changed:", and the resolution records "told <seat>" so the row shows the asker knows. A deny with no reason tells the agent to ask before retrying. Rows with options get Reply and Done for now: the daemon's `answer` verb has no CLI wrapper, only `POST /api/mission-control/action`, which accepts a loopback call without a bearer and records the `X-OpenRig-Session` actor.
- **`just test-rig <seat>@<throwaway rig>`** runs the app's create, block, resolve, close and send as the person and checks every transition names them, then has the seat ask the person and runs `Answer(.approve)` through the real CLI. Passed on `openrig-apptest`; ⌘↩ in the app did the same end to end. A test seat acts on the "Approved" messages it gets, so brief it to ignore them or it stops at a permission prompt and later sends are refused (`target_needs_input`).
- **`RigCLI.run` hung** in `waitUntilExit` (called from a detached task) after the `rig` child had exited. It now waits on a `terminationHandler` set before launch, in a detached task so cancellation can't read the status of an unreaped child.
- **Rows from other rigs.** A rig's queue lists only its own seats' rows, so the app also asks for open rows addressed to the person (`/api/queue/list?destinationSession=…&state=pending,in-progress,blocked`, for the registered address and the legacy `human@host` and `human@kernel`) on each rig-list refresh and on another rig's `queue.*` event. Those from other rigs sit in Needs you under each rig's name and count in its badge; opening one selects that rig's queue board, the row and the inspector. Any `queue.*` event refreshes them, so a row answered on its own rig doesn't reappear elsewhere. Each rig's sidebar row carries a count of what waits on you there (`Waiting`, RigDomain): coral for asks and prompts, grey when only FYIs wait, with "1 ask · 1 prompt · 1 FYI" on hover. The selected rig counts its own Needs-you list; another rig counts its rows for you plus the daemon's `attentionCount` (seats needing attention; an asking seat isn't in it, so asks aren't counted twice). The toolbar's Needs-you count is the sum of the rig badges, and Needs you lists another rig's prompts as "N seats need you", opening its canvas. `attention=1` would be one call, but it leaves out FYIs.
- **Answering options.** A row with questions shows one radio list per question, each with "Other…" for the person's own words, and one Send answers (⌘↩). `QuestionAnswers` (RigClient, tested) sends each pick with the daemon's `answer` verb, then any "Other…" words in one call; the daemon records them, returns them to the asker as one reply row (tagged `human-answer`) and closes the ask, which then reads "Answered" with the picks listed in the inspector. The verb has no CLI wrapper, so this is the app's one HTTP write: `POST /api/mission-control/action` with `X-OpenRig-Session` naming the person. It passes without a bearer only while the daemon has none configured (loopback); with one set the send fails and shows the daemon's message (not tested against a token-protected daemon), and the TUI's Feed remains the way in. Picks already recorded on the row (an interrupted send) aren't sent again. Live-tested by `just test-rig`.

### Closed rows in plain words
- A finished row's tag says how it ended in one word (`Outcome`, RigDomain): Approved (green), Denied (red), Done, Canceled, Replaced, Escalated or Handed off, not the daemon's `Closed · no-follow-on`. An approval is a `no-follow-on` close whose resolution starts "Approved", as the app's answer and the TUI's approve write it.
- On a card the tag and closing time sit at the leading edge (a narrow Done column cuts off the trailing one); the time gains a date when it isn't today. The inspector adds "Approved by you · 11:42". Rows don't record who closed them, so the inspector reads the actor of the last transition into a finished state (`/api/queue/<id>/transitions`), refetched when the selected row's outcome changes.
- `OPENRIG_DEBUG_SCOPE=today` opens the board on Today, for screenshots of closed work.

### Settings
- **Window.** A `Settings` scene with four grouped forms (General, Connection, Notifications, Terminals), designed on the Paper page "Settings window" and reviewed by UX and UI passes. Preferences live in `UserDefaults` (`AppSettings`); the operator token lives in the Keychain (`OperatorToken`).
- **Polling at app lifetime.** Polling and the event stream used to be `.task`s on the window, so closing it stopped every update. `AppStore.start()` now runs them from launch, which the Dock badge, the menu bar list and banners depend on. Verified with `OPENRIG_DEBUG_BADGE=<file>`: with the window closed, each 5 s poll still set the badge.
- **Connection.** A custom address beats `OPENRIG_URL` and `daemon.json`, and is passed to `rig` as `OPENRIG_URL` so reads and writes reach one daemon; it is used only once Test gets an answer. The token goes out as `Authorization: Bearer` from the HTTP client and as `OPENRIG_AUTH_BEARER_TOKEN` to the CLI (rig's `operatorAuthHeaders`). Picked tools override the search paths; a picked node's folder is prepended to PATH. `Tmux.locate` now honours `OPENRIG_HOME`. Checked against a closed port (`127.0.0.1:9`), and through a local proxy that refuses writes without the bearer: with the token in the Keychain, the app's reads carried it, and a gated `rig queue resolve` passed the gate while the same call without it got "Operator bearer required". Ungated writes (`queue create`) send no bearer, as in rig itself. A real token-protected daemon is still untested. Settings checks the token without changing anything: an `answer` to a made-up row passes the operator gate and is refused as not found (the real daemon returns 404 `qitem_not_found`), while a missing or wrong token stops at the gate (401/403). Through the proxy, Connection then said the daemon asks for a token.
- **Tools from the shell's PATH (2026-11-24).** An app opened from the Dock gets launchd's PATH, so a `rig` and `node` installed under nvm, asdf, mise or Volta weren't found until picked by hand. `ShellPath` (RigClient, tested) asks the login shell once per launch, off the main thread: `$SHELL -ilc` prints PATH after a marker and only the last marked line is read, since startup files print their own text. The shell gets `OPENRIG_RESOLVING_ENVIRONMENT=1`, so startup files can skip slow work. It has to be interactive: on this Mac `zsh -lc` misses nvm (loaded from `.zshrc`), `zsh -ilc` finds it in about 1.3 s. Lookup order is the pick in Settings (a pick that's gone still gives nil), then the shell's PATH, then the Homebrew paths; `rig` and the Settings version check run with the picked node's folder, then the shell's PATH. A shell that fails or hasn't finished in 5 s leaves the old lookup: interactive zsh ignores SIGTERM, so a late shell gets SIGKILL and a late PATH is never used, and the read ends once the shell has exited and printed its PATH, since a background job from a startup file can hold stdout open. Verified on a background copy launched with PATH `/usr/bin:/bin:/usr/sbin:/sbin` and no picks: Connection showed the nvm `rig` 0.7.22 and `node` as found, not chosen.
- **Keychain at launch.** The token was read on the main thread, so a Keychain prompt (every ad-hoc rebuild changes the signature, and an item another tool wrote always asks) froze the app at launch. It is now read in the background; the app polls without it until the person answers.
- **Banners.** `Notices` (RigDomain, tested) turns what waits into banners, keyed so a refresh never reposts and a new prompt on the same seat does; nothing waiting at launch is replayed, and daemon-down waits 30 s. Other rigs only give a count, so their banners name no command. Clicking opens the prompt, row or rig; banners carry no actions. Seen live with `OPENRIG_DEBUG_PROMPT_AFTER` (a fake prompt that arrives after launch) and `OPENRIG_DEBUG_BANNERS=<file>`: with the window closed, "orch-lead needs permission" appeared once notifications were allowed. A real click reached the app and selected the seat (logged as `clicked` then `show: selected`), and the window reopened. `OPENRIG_DEBUG_SHOW` replays a click: the window reopens on the canvas with the seat selected and inspected. Not proven: that a real click leaves the seat selected on screen. The one capture after a real click showed no selection, but it was taken minutes later, and macOS offers no scriptable press on a banner to repeat it. While notifications are denied, the app stops at the permission check and posts nothing.
- **Deferred.** "Offer Allow once in the banner" (needs the per-prompt check the inspector does, against a banner that can sit in Notification Center for hours) and "Read prompts on every rig" (polling every rig's panes) are shown disabled as coming later.
- **Terminals.** The smallest tile text (default 8.5 pt) replaces the fixed floor. "Start typing on focus" never starts on a tile showing a prompt, since Enter there answers it. Esc can go to the pane (`TerminalKeyContext.escGoesToPane`), leaving ⌘T as the way out.
- **Menu bar icon, 2026-11-23.** Paper page "Menu bar icon · options", backed up in `design/ui/9-menu-bar-icon/`.
  - The item shows the rig mark, not a bell. `MenuBarMark` in `App/Assets.xcassets` is a template SVG: `rig.svg`'s seat centres at 16/700 pt per unit, seats radius 100 units, not 118, so they stay about 1 pt apart at 18 pt. Not `circle.hexagongrid`, which has two seats on top.
  - Asks and prompts show as a count beside the mark (option A). FYIs alone leave it quiet, as the Dock badge. VoiceOver reads `Waiting.menuBarLabel`: "OpenRig, 2 need you".
  - A `.canary` bundle id gets `MenuBarMarkCanary`, whose centre seat is a ring: the canary's yellow can't show in a one-colour menu bar.
  - A `Label` in a `MenuBarExtra` draws only its image. The old bell's count never showed. Measured through AX on background copies: a `Label` with a count is 36 pt wide, as quiet; an `HStack` of image and count is about 50 pt, quiet 36 pt.
  - A status item has no window to capture on macOS 27; read it through AX by pid (`menu bar 2` of the process). Its look in the real menu bar is checked by the person.
  - The item is on when `menuBarItem` is absent. A stored value or a `-menuBarItem` launch argument wins.
  - `menuBarItem` saves only on change. Saving every write stored "off" at launch for every existing user.
  - The person chose to keep a stored "off": no migration. Existing users turn the item on in Settings › General.
  - Seat copies' status items sat off screen at (-1, 1068). Not the Menu Bar allow list: the person's System Settings › Menu Bar shows OpenRig allowed. Cause unknown.


### Design review, 2026-11-19 (platform conventions, accessibility)

The review is in `design/reviews/2026-11-19-quick/` (finding ids below).
- **Done:**
  - AX-04-01, AX-05-01: VoiceOver reads tiles; snapshot terminals leave the Tab order.
  - PC-03, PC-04, PC-08, PC-09: menu commands. ⌘N queues a task; New Window is ⌥⌘N.
  - AX-03-01, AX-03-02, AX-03-03: spoken names, and the canvas read pod by pod.
  - AX-06-01: announcements.
  - AX-01-01, AX-01-02: contrast.
  - AX-02-01: needs-you wires dash-dot only under Differentiate Without Color.
  - AX-09-01: 24 pt zoom targets.
  - AX-10-01: tile order held under the pointer or VoiceOver.
  - PC-05-01, PC-06-01.
- **Checked from the in-app AX dump** (`OPENRIG_DEBUG_AX`) with the screen locked: tiles, picker, footer, zoom and canvas order.
- **Not seen live:** menu items enabling per view (no key window while locked), hover freezing, Settings reopening on its last tab.
- **Open:**
  - AX-02-02: sidebar badges differ by fill and lightness; the label carries the summary.
  - AX-08-01: "Sent" still hides after 1.5 s; it is now also announced.
- **Launch.** Giving the main `WindowGroup` an id (for New Window) let state saved by a killed process restore no window. `.defaultLaunchBehavior(.presented)` opens one anyway.

### Design review, 2026-11-20 (all five lenses)

The review and fix log are in `design/reviews/2026-11-20-full/` (`review.md`, `progress.md`; numbers below are its items).
- **Done:** 1 launch crash (inspector waits for room; ⌃⌘I widens a narrow window), 2–9 (VoiceOver groups, prompt
  contrast, canvas 100% floor and stacked answers, drafts, Needs-you reveal), 10–12, 14–18, 20–22, 24, 25, 28, 30–32,
  34–41. Also from use: Type mode shows the top of full-screen apps and keeps its pan through resizes.
- **Not seen live:** Increase Contrast variants; drafts surviving a dismissal (needs typing into a live app); result
  lines after a commit; ⌘[ (⌘] checked).
- **Decided and done 2026-11-20** (options drawn in Paper, page "Review 2026-11-20 · decisions"; commits cf87e8e..07c306c):
  - 13: freeze the canvas layout while the pointer or VoiceOver is on it; the grown card may overlap the seat below.
  - 23: moving work (in-flight and next-hop wires, In progress) turns green; orange means only "look at this".
  - 27: keep "qitem" (the CLI's word); one word for the blocked state, no "unpark".
  - 29: success lines stay until the next action.
  - 19: a ⌘K Go to… palette for rigs, seats and tasks.
  - 26: a drafted icon from the rig mark, replaceable later.
  - 33: Help › OpenRig Help (⌘?) opens openrig.dev.
  - PC-09-01: the window's minimum width grows while the inspector is open.

### Rig controls, 2026-11-20

Picked in Paper, page "Rig controls · options" (`design/ui/6-rig-controls/`).
- **Status:** each sidebar row shows a state dot and one line from `rigLine`: "up 3d · 7 seats", orange "degraded · 6 of 7 seats", hollow "stopped · snapshot 2h ago". It comes from `lifecycleState` and `latestSnapshot` in `/api/ps`.
- **Stop:** a toolbar power button (and Rig › Stop Rig…) opens a popover that names seats mid-turn, then runs `rig down <rig> --snapshot --yes`. There's no snapshot checkbox, because `rig down` snapshots anyway. There's no force stop in v1.
- **Stopped rig:** a taller banner with Start Rig (`rig up <rig> --existing --yes`). The view stays readable, dimmed.
- **Starting:** `rig up` returns in about 1.5 s, before the harnesses are ready. The subtitle and seats follow `startupStatus: "pending"` ("starting…"); seats not yet launched read "waiting to start".
- **Seat down:** Resume Seat runs `rig launch <rig> <logicalId>`, and Start Fresh… runs `rig seat launch <seat> --fresh --reason …`. Both leave the other seats alone: `nonTargetEffects: unchanged`, and sibling tmux session ids are kept.
- **Verified live** on a throwaway rig (one terminal seat, one Claude seat), since deleted:
  - `just test-lifecycle <rig>` covers down, up, and kill-then-resume.
  - Each control was pressed in a background copy through AX: Start Rig, the Stop popover's Stop, and Resume Seat.
  - Fixtures recorded from it: `ps-stopped`, `graph-stopped`, `graph-starting`.
- **Not seen live:**
  - Start Fresh's confirmation dialog in the app. Its command was run through the CLI.
  - Pointer and keyboard paths: Esc closing the popover, and Return not stopping.
  - A failed start or stop banner.
- **Existing crash, not from this work:** the window aborts with "more Update Constraints passes than views" when `OPENRIG_DEBUG_SIZE` resizes it with the inspector open. Reports from 15:53, 17:17 and 17:27 predate this work.

#### Design review of the rig controls, 2026-11-20

The full panel was run on this diff; the run is in `design/reviews/2026-11-20-rig-controls/` (`review.md`, `progress.md`). It confirmed 16 findings and downgraded 5; all 13 resulting fixes are done:
- A stopped rig isn't dimmed (its text fell to 2.7:1). Its seats read "stopped" with a hollow ring, not the crash ✕.
- The light-mode text colour for "look at this" (`Color.lookText`).
- attention_required reads "needs you · N seats" in coral, matching the seat. `generation_mismatch` reads "no report since restart".
- One power item in every state (Stop Rig… / Start Rig) in its own glass group. Stop Rig… goes through the focused window.
- Keys: ⇧⌘U Start Rig, ⇧⌘D Stop Rig…, ⌘↩ Stop N Seats.
- "<rig> is up" is announced. Stale success lines clear. A failed start or stop leads with "Couldn't …" and offers Try Again.
- The subtitle matches the sidebar. A busy ring in the sidebar. Resume Seat leads over Start Fresh. Commands are shown without `--json --yes`.

**Seen during capture:**
- Twice a background copy sat at 100% CPU after an `OPENRIG_DEBUG_SIZE` resize on a stopped rig. One stopped answering AX for 50 s. The other read 100% at 5 s and was killed before it could be told apart from startup. A third launch at 900×600 was clean.
- **Open bug, bisected 2026-11-21: the stopped rig's canvas spins and aborts, from `daed41f`.** A plain launch reproduces it, with no debug hooks, when the saved state is a stopped rig on Canvas in a 900×600 window. The copy spins at 100% CPU and aborts about 13 s later with the "Update Constraints" exception listed above (`SplitViewChildController … didUpdateMinSize`).
  - Stopped throwaway rig, `OPENRIG_DEBUG_OPEN=<rig>/canvas`, started from a saved 900×600 frame: `3efb5e1`, before the rig controls, was fine 4 of 4. `daed41f`, `876516e` and `b50ae9f` each spun 4 of 4.
  - On the same build and window, kernel's canvas (running) and the stopped rig's Queue view settled within 2 s.
  - While it spins, the window's width jumps (900 → 1220 → 900 → 976) as the inspector opens. The detail column is measured mid-animation (0 to 670).
  - Not the cause on its own, tried one change at a time. With the stopped banner removed, 1 of 3 still spun. With a floor that never exceeds the window's width, 6 of 6 spun. With a constant 820 minimum width, 5 of 5 spun.
  - The earlier verdict on this line, that the debug hook's `setFrame` was the cause, was wrong. The hook only kept the restored view on screen for 3 s before switching to Terminals. Moving the frame off (0, 0) didn't help (4 of 5 spun).
  - Next: bisect `daed41f`'s app hunks against `3efb5e1`.
- **Found 2026-11-21: the spin was the window's minimum width feeding itself.** A running rig did it too (denkeeper, Canvas, 900×600, inspector open), after a sidebar toggle or a window resize. `OPENRIG_DEBUG_WIDTHS=<file>` traces the widths.
  - The minimum was window width minus detail width. The two were read a frame apart, so the value swung (320 to 859 pt at one window width), the window grew (900 → 1489) and was measured again. Now each side pane is measured itself.
  - The detail width was `@State`, so every point of a column animation re-ran `ContentView.body` and rebuilt the toolbar. The reasons are at the properties in `ContentView.swift`.
  - On a Touch Bar Mac the loop aborts within seconds: the Touch Bar's window allows 3 layout passes per display cycle, the main window about 200.
  - Before: a sidebar show at 900×600 spun 5 of 5 and never settled. After: 0 of 15, and scripted resizes from 820 to 1300 settle.
  - **Open:** the first sidebar show after launch still runs hot for about 3 s (framework layout, no app code in the sample). A real pointer drag is not checked.

### Images on queue rows, 2026-11-24

Plan: `.claude/plans/row-images/plan.md`. A row's images are thumbnails in the inspector; one opens in Quick Look, and the arrow keys step through the rest.
- **Rules** (`RowImages.find`, RigDomain, tested on real files):
  - It reads `evidenceRef` and the body. A body path is a one-line `backtick` span, a Markdown link's target, or any run with "/" in it, fenced code included.
  - A path is absolute, `~/`, or relative to the source seat's `launch_cwd` (from `/api/seat/status`). Only paths that exist count.
  - A folder gives the images directly in it, hidden files and subfolders skipped. The home and launch folders themselves give nothing.
  - Images group by folder, in the order folders are first named, and in number order within one (`2-` before `10-`). Symlinks are resolved, so each file shows once.
  - Nothing is read when the daemon isn't on this Mac.
- **Where:** on an open row for the person, in the For You panel above the questions, under the evidence line. The line stays unless `evidenceRef` itself named the images: a branch or a report is what the agent asked the person to judge. On any other row, an "Images" section in the same place, and no line (those rows never showed evidence). Never both.
- **Layout:** two to a line in the usual inspector width, each with its file name (the questions say "Board 2"). Six at most, so Approve and Deny stay in a 900 pt window, then "N more"; Quick Look still steps through all of them.
- **Loading:** the evidence line shows at once. The inspector then finds the images off the main thread: first without the launch folder (absolute and `~/` paths), then with it. The folder is kept 30 s per seat, and so is a failed lookup. Quick Look draws each thumbnail at its shown size, so a 6000 px board is never loaded whole.
- **`OPENRIG_DEBUG_ROW=<file>`** (DEBUG): rows from a JSON file, one or an array as `rig queue show --json` prints them, join the open rig's queue unless a real row has the same id. Open one with `OPENRIG_DEBUG_OPEN=<rig>/queue/<id>` to see an ask with images or questions that nobody sent. Nothing on one reaches a seat or the daemon: ActionStore refuses every action under its id (`MadeUpRows`, tested), and the panel hides Tell and Reply…. They never post a banner.
- **Seen in a background copy** with a made-up ask whose `evidenceRef` is a folder of the four iOS boards:
  - four thumbnails, two to a line, above the questions;
  - each a button named by its file;
  - one AXPress opened Quick Look on board 1 with previous and next arrows, and the frontmost app didn't change. The panel floats, so it showed over other windows until the copy quit.
- **Not seen:**
  - q-f0af through a seat's launch folder. That folder is in iCloud Drive, and a privacy prompt for a new bundle id would take the person's focus. The unit test covers its real `evidenceRef` and body.
  - Whether macOS asks for access to iCloud Drive, Desktop, Documents or Downloads the first time.
  - A real click, Space and the arrow keys, and Tab with Full Keyboard Access.

### Refresh load, 2026-11-24

Plan: `.claude/plans/refresh-load/plan.md`. The app asked the daemon for far more than it showed: every refresh read the rig's newest 500 rows, closed ones included, and every `queue.*` event re-read the rig list, identity and rows for the person.
- **Events without `rigId` are placed by what they name** (`EventReach`): the sessions (`<seat>@<rig>`), then seat ids, then row ids the store holds. `queue.updated` names only its row and actor. An event that names nothing refreshes the selected rig, as before. The daemon needs no change.
- **The gate** (`RefreshGate`): a refresh starts 250 ms after the first event, then no sooner than 2 s after the last one started, and never two at once. The person's own actions (answering, Refresh, Retry, switching rig) and the 15 s poll skip it.
- **Open rows on refresh, closed rows on demand.** Today's closed rows are read while the board's Today scope or ⌘K shows, and topped up on each refresh while held. A selected closed row and its chain are read by id. ⌘K lists open rows plus today's closed ones.
- **`OPENRIG_DEBUG_REQUESTS=<file>`** (DEBUG) writes one line per daemon request: time, method, path and query, status, bytes, ms. **`OPENRIG_DEBUG_GOTO=1`** opens ⌘K after launch.
- **Measured**, before (`2483d23`) and after side by side, same view, 2.6 min, daemon near idle (1 event): requests equal at about 72 a minute (both just poll); bytes 18.5 MB → 0.9 MB; the rig's `queue/list` 17.8 MB → 198 KB.
- **Not measured:** the drop in requests under event load. The only evidence is task 4's 126 s log on a busy rig: the rig list and participants read only by the 15 s poll, and rows for the person by the poll plus 2 event reads.

### iPhone remote, 2026-11-24

An iPhone app (`Remote/`, `OpenRigRemote`) that pairs with the Mac app from a QR code. At home on the same Wi-Fi it shows what waits on the person and lets them act on it. How to install and pair it is in the README. The boards are in `design/ui/11-ios-remote/`.

**A daemon on Wi-Fi is open to the whole network.** This is from rig 0.7.21's shipped source and docs. No route was called from another device.
- `rig daemon start --host <Wi-Fi address>` refuses to start without `OPENRIG_AUTH_BEARER_TOKEN`. That operator token, and the terminal token, guard only:
  - Mission Control's writes;
  - hosts and rig-mode writes;
  - issuing and revoking app credentials, `/api/apps/v1/credentials` (operator token);
  - starting seats, `/api/startup` (terminal token);
  - on a Wi-Fi bind, `/api/transport`, `/api/compaction` and `/api/terminal`.
- Every other route has no token check:
  - `/api/queue`, `/api/transcripts`, `/api/ps`, `/api/rigs`;
  - `/api/up`, `/api/down`, `/api/seat`, `/api/files`, `/api/config`.
- So anyone on the Wi-Fi could read every seat's transcript, and queue a task to a seat that runs with automatic permissions.
- `X-OpenRig-Session` names the caller but isn't authentication. The traffic is plain HTTP.
- A `--host` bind serves only that address, so loopback goes. With the token set, every seat's `rig send` needs it too.
- **So the phone goes through a relay in the Mac app.** This was the person's answer A (2026-11-24 01:37Z).
  - The daemon stays on loopback and isn't restarted.
  - No operator token exists to leak, and other devices on the Wi-Fi reach nothing.
  - The cost: the Mac app must be running, and a sleeping Mac answers nothing.

**The relay.** `RelayServer` is in RigClient; `RelayStore` starts it in the Mac app.
- **The link:** Network framework TLS 1.2 with `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256` (0xCCAC). The pre-shared key authenticates; an ephemeral ECDH key gives forward secrecy. TLS 1.3 with an external PSK fails in Network framework (-9858 on macOS 27).
- **The keys:** one PSK per paired phone, under its credential id. The key is HMAC-SHA256(pairing secret, "openrig relay psk v1"). The 256-bit secret travels only in the QR code or link, never over the network.
- **Frames:** a 4-byte big-endian length, then a JSON `RelayRequest` or `RelayResponse`. `more` marks a streamed frame. A frame over 8 MiB is refused.
- **An allowlist,** checked on decoded path segments:
  - The seven app-contract routes go to the daemon, on a path rebuilt from the checked segments.
  - The Mac-side calls under `/relay/v1/` go to `MacRelayDesk`, which acts through `ActionStore` as the Mac's person. They are: Needs you, a prompt, allow once, decline, reply, got it, done, message, task, rigs, and a rig's seats.
  - Anything else gets 403.
- **Acting calls refuse:**
  - while any phone paired on this daemon answers as someone other than the Mac's person (`actor_mismatch`). The relay can't tell which phone is calling.
  - a row that isn't waiting on the person (`not_for_you`).
  - a prompt whose command or `observedAt` changed (`prompt_changed`, `prompt_gone`).
- **When it listens:** port 7434, or a free port if that one is taken; the code carries the port. It listens only while "Let paired phones connect" is on and a phone is paired or a code is showing.
- **Where it binds:** a Debug build binds 127.0.0.1 unless `OPENRIG_RELAY_WIFI=1`, because seats run debug copies, and a Wi-Fi listener can put a firewall prompt on the person's screen. Release binds all interfaces.
- **Unpair** revokes the phone's credential and drops its key. The relay then restarts, which cuts the phone's connections.
- **On the phone:**
  - The app contract goes through `RelayTransport`, one channel per request.
  - The Mac-side calls go through `RelayDeskClient`: one call at a time on one channel, 15 s per call.
  - A call that never went out is tried once more. A read whose reply was lost is asked again. An acting call whose reply was lost isn't. The exception is Allow once and Decline, which are resent once, because the Mac's `observedAt` check stops a second answer.

**The person's picks**
- **Reach:** the same Wi-Fi now. The pairing code lists reaches by kind (`loopback`, `lan`, `tailnet`), so Tailscale is a kind to add, not a redesign.
- **Scope C:** asks, permission prompts, messages and tasks. FYIs, asks without options and held rows come along, so an empty list never hides something waiting.
- **Notifications:** not in the first version.
- **Boards:**
  - 1B, a tab bar.
  - 2, every question on one page with one Send. Steps wait until the phone can show images.
  - 3B, an explainer before the scanner, with Paste.
  - 4A, a Phone tab in the Mac's Settings.
  - 5A, a prompt on its own screen. Allow once is off until the end of a long command has been shown; Decline takes an optional reason; the buttons go if the prompt changes.
  - 6B, a Rigs tab: rigs first, then a rig's seats.
- "Always allow" stays on the Mac.

**DEBUG launch hooks**
- **Phone** (pass them to `simctl launch` with the `SIMCTL_CHILD_` prefix):
  - `OPENRIG_DEBUG_PAIR_LINK=<link>` pairs at launch.
  - `OPENRIG_DEBUG_OPEN_LINK=<link>` handles a link as opening it does, and waits for the confirmation.
  - `OPENRIG_DEBUG_RELAY_HOST=<host>` sends every `lan` reach to that host, still through the relay. Use `127.0.0.1` to reach a Debug Mac copy.
  - `OPENRIG_DEBUG_STATE=unreachable|local-network-denied|unpaired|unsupported` replaces the status after each check.
  - `OPENRIG_DEBUG_SCREEN=scanner|settings|rigs`.
  - `OPENRIG_DEBUG_OPEN_ASK=<id>` and `OPENRIG_DEBUG_DRAFT=reply:<text>` or `picks:<question>=<option>,…`.
  - `OPENRIG_DEBUG_RIG=<rig>`, `OPENRIG_DEBUG_SEAT=<session>`, `OPENRIG_DEBUG_COMPOSE=message|task` and `OPENRIG_DEBUG_TEXT=<text>` open the Rigs tab on a seat, a sheet and its text. `OPENRIG_DEBUG_SEAT_PROMPT=1` opens that seat's prompt screen.
  - `OPENRIG_DEBUG_OPEN_PROMPT=<session>` and `OPENRIG_DEBUG_OPEN_ROW=<row id>` open a prompt or a row from Needs you.
  - On the opened prompt: `OPENRIG_DEBUG_PROMPT_ACTION=allow|decline|decline:<text>`, `OPENRIG_DEBUG_DECLINE_TEXT=<text>`, `OPENRIG_DEBUG_PROMPT_SCROLL=end`, and `OPENRIG_DEBUG_PROMPT_OUTCOME=lostReply|probablyAnswered|answeredThenNewPrompt|unreachable|cannotAllowOnce`, which shows that outcome without sending. `OPENRIG_DEBUG_ROW_ACTION=reply` opens the opened row's Reply sheet.
  - `OPENRIG_DEBUG_SEND=1` sends the opened ask's draft or the opened sheet. Use it against a fake daemon or relay only.
  - `OPENRIG_DEBUG_CONFIRM_PAIR_AGAIN=1` and `OPENRIG_DEBUG_UNSENT=<n>` (made-up unconfirmed answers) open the pairing confirmations.
- **Mac:**
  - `OPENRIG_DEBUG_PHONE=pairing|paired` opens Settings › Phone in a made-up state. It uses a fake token, and nothing is issued, revoked or saved.
  - `OPENRIG_RELAY_WIFI=1` binds a Debug build's relay to the Wi-Fi. Launch with `open --env`, since `just run` doesn't pass it through.

**Checked, and not**
- **Checked by seats:**
  - Every screen in a headless simulator, against loopback relays with made-up desks or a fake daemon.
  - The link, its refusals and the client's retries, in kit tests against real `RelayServer`s on 127.0.0.1.
- **Not checked by a seat:**
  - A real phone: signing, install, the camera, the Local Network prompt, real Wi-Fi.
  - A Mac that sleeps or changes address.
  - A message, task or answer reaching a real seat.
  - Whether the link holds against someone listening. The tests show the secret is required; they aren't a security review.

**Later**
- **Time in state** ("4m"), a seat's model, and its current row's id and age. The relay's seat list doesn't carry them.
- **Per-rig counts** (working, asks) on the phone's rig list. A rig row shows its seat count and a badge of what Needs you lists for it; the badges add up to Needs you's.
- **A closed event stream:** the relay notices that the phone closed one only on its next write.
- **A clean close while idle:** if the Mac closes a connection cleanly while it's idle, the phone's next call reads as a lost reply. Reads retry; actions aren't resent.
- Tailscale reach, and notifications.

### New Rig from a template, 2026-11-25

Rig › New Rig… (⇧⌘N, and the sidebar; see Ways in) opens a sheet with three steps: Start, Seats and Review. Mocks: the person's Rig Builder canvas, boards 1–3.
- **Templates:** the library's rig specs (`GET /api/specs/library?kind=rig`, then each one's `/review` for its text), built-in first. Managed apps (`hasServices`, such as secrets-manager) and the built-in `kernel` are left out: the first starts services, and the second says it is a preview of the running kernel. Blank rig waits for a later slice.
- **The spec:** `RigDraft` (RigDomain, tested) parses the template with Yams and changes only `name`, each seat's runtime, model and effort, and the removed seats.
  - A removed seat takes its pod edges and its rig edges with it; a pod left empty goes too.
  - Every other key stays, startup files and env included.
  - A saved spec can't use `..` or absolute paths for `culture_file`, docs or startup files (`rig spec validate`). Only an agent ref may be absolute (`path:`). So `local:` refs become `path:<absolute>`, and Launch copies the template's folder beside the new rig.yaml. A template that is a lone file at the top of `~/.openrig/specs` gets only its rig.yaml, as its folder is the whole library.
  - Switching a seat to `terminal` writes the schema's terminal triple (`builtin:terminal`, profile `none`) and drops the keys only an agent seat may carry. A template's terminal seat stays a terminal.
- **Models and effort come from each runtime's CLI:** Codex from `codex debug models` (its local catalogue, no model call), showing its picker's models (`visibility: list`) in its order, each with its own levels. Claude Code from `claude --help`, using the aliases quoted under `--model` and the levels under `--effort`. Other runtimes offer only "Role default" (the model is left out) and "Default". A template's own model stays in the list. A model change drops an effort the new model doesn't accept. "Role default" names what it means: the role's model (its profile's `preferences.model`, else the agent spec's `defaults.model`, OpenRig's order), else "Claude Code's default" / "Codex's default". The label follows the seat's runtime: on a runtime other than the role's own (`preferences.runtime`, else `defaults.runtime`, else claude-code) it names that runtime's default. OpenRig itself still passes the role's model to the switched runtime; no shipped role sets a model, so that's a note, not a fix here. "Other…" takes a full model ID (`claude --help` lists only aliases), trimmed, written as typed. (Person's second hand test, 2026-11-26.)
- **Review** writes the spec folder to a temp directory and runs `rig up <spec> --plan --json` on it, so what Launch adds is what was checked. It also refuses a name an existing rig or `~/.openrig/specs/<name>` already has: `rig specs remove` leaves a folder spec's other files behind, and `rig specs add` then refuses the name. Correction (2026-11-25): it first used `rig spec preflight`, which resolves each seat's `cwd: "."` against the spec's own folder, not the project. On a template left in place, that flagged "inside the OpenRig installation" for every seat. The plan runs the same preflight with the real `--cwd`. Correction (2026-11-26): `--cwd` lasts one run, so a later `rig up <name>` started the seats in `~/.openrig/specs/<name>`. The saved spec now writes the project's absolute path as every seat's `cwd` (a template's relative cwd, such as `docs`, inside it; an absolute or `~` one as written), and no command passes `--cwd`. Seen live: a rig from the saved spec, launched from `~` with no `--cwd`, had both seats in the project folder. `rig up --plan` (0.7.22) doesn't print a cwd.
- **Preflight's messages** (`PreflightNote`, RigDomain, tested): OpenRig reports each check once per seat, and says "no permission policy" twice in different words, so Code review gave nine lines. Review shows one row per thing, naming its seats ("lead, r1, r2"). Known messages get plain words, with OpenRig's own as the row's tooltip; others keep OpenRig's words. Errors stay open, above the warnings. Warnings fold behind their count. The model warning comes for any configured model, an alias like `opus` or a full id, because launch checks make no model call. So it is explained, not avoided.
- **Fits the window:** the sheet sizes to its parent window (at most 960×640, with a 40 pt margin) and follows its resizes. Each step scrolls, and the footer (Cancel, Back, Continue or Launch Rig) is always shown. Review puts the rig.yaml beside the checks when there's room, else below. At the smallest window (820×520), AX frames put every step's footer buttons inside the sheet and the sheet inside the window.
- **Ways in:** Rig › New Rig… (⇧⌘N), the sidebar's New Rig button above the daemon status, "New Rig…" on a right-click in the sidebar's empty space, and the empty sidebar's button.
- **Launch** runs `rig specs add <folder>`, then `rig up <saved rig.yaml> --yes`, both through ActionStore. The sheet shows the commands with full paths, because a quoted `~` doesn't expand when pasted. If `up` fails after the save, the spec is in the library: Review then writes and preflights the saved rig.yaml itself, and Launch runs only `rig up` on it (`SpecLaunch`, tested). So a retry runs the edits that were checked, and the name and template are fixed from then on. Cancel removes the staged folder. Seen live: a rig holding the name made `rig up` fail after the save. A seat was changed to terminal, the saved rig.yaml got it, and once that rig was gone the retry brought the rig up. Once `rig up` returns, the rig list refreshes until the new rig is there, and it is selected.
- **`OPENRIG_DEBUG_NEWRIG=<folder>`** (DEBUG) opens New Rig with that project folder, since the folder panel can't be scripted.
- **Seen in a background copy** (AX, starter template, rig `openrig-apptest-newrig`):
  - the roles (implementer, qa);
  - Claude Code's models (Fable, Opus, Sonnet) and Codex's catalogue;
  - the effort reset;
  - preflight passing with its two warnings;
  - Launch bringing the rig up with 2 seats (stub and terminal), selected in the sidebar, with the spec in the library;
  - a second New Rig refusing the name.
  - The rig and the spec were then deleted.
- **Not seen:** real clicks and keys, the folder panel, and a launch with claude-code or codex seats (never in a test).

### New Rig seat detail, 2026-11-26

On Seats, a seat's name opens its detail (a terminal seat has none: it runs a shell). Mocks: the Rig Builder canvas, board SeatDetail.
- **Layers come from OpenRig, not the mock.** The daemon's `resolveStartup` and the startup guide's layering model give the order: agent spec startup files, then its profile's (Role); OpenRig's `CULTURE-default.md`, then the rig's `culture_file` (Culture); the rig's, then the pod's startup files; the member's own (Seat startup, the template's); then OpenRig's start files (`openrig-start.md`, `openrig-context-entry.md` and, on a fresh start, the two onboarding files). Project instructions aren't one of OpenRig's layers. The harness reads them itself, with the merged layers inside, before anything is sent, so they're shown first. The mock had culture before role; OpenRig delivers role first. Empty rig, pod and seat layers are left out.
- **Each file says how it arrives.** `auto` is resolved as the daemon resolves it: a role file (`orientation: role` or `guidance/role.md`) is sent, a SKILL.md is installed, other Markdown is merged into the instruction file, and anything else is sent. Claude merges into the rig's `managed_blocks` file (default CLAUDE.md); Codex, Pi, OMP and the stub merge into AGENTS.md.
- **Shared layers are read-only:** a 12-line preview and Open File (`NSWorkspace.open`, the person's default app). OpenRig's own files are found from a built-in template's path (`…/daemon/specs/…` → `…/daemon/assets`).
- **Seat notes** become the member startup file `seat-notes/<pod>.<member>.md`, beside rig.yaml, with `delivery_hint: send_text`. Not merged: a merged block lands in the instruction file every seat in that folder reads.
- **Added skills:** a rig spec member has no skills field. A member startup file `seat-skills/<pod>.<member>/<id>/SKILL.md` with `skill_install` is how one seat gets one. The skill's folder is copied beside rig.yaml, one folder per seat, so two seats' same-named skills don't overwrite each other. A linked folder or a linked SKILL.md is copied as its target, since a relative link would dangle (found by QA and review). OpenRig installs only that SKILL.md, not the folder's other files, and the detail says so. The role's skills are its profile's `uses.skills`. The choices are the skill pools of the role's agent spec and the specs it imports (OpenRig's shared pool, for the built-in roles), the project's `.claude/skills` and `.agents/skills`, and `~/.openrig/skills`. The role's own skills, and ones already added, are left out. The context library holds context packs, not skills, so it isn't a source.
- Nothing writes to the agent spec. Review writes the notes and skill folders into the staged (or saved) spec folder before `rig up --plan`.
- **`OPENRIG_DEBUG_NEWRIG_RUNTIME=<runtime>`** (DEBUG) puts every agent seat on that runtime when a template is picked. A pop-up menu can't be chosen from in a background copy.
- **Seen in a background copy** (AX, starter template with stub seats, rig `openrig-apptest-sd1`):
  - the layers in that order, from the seat link;
  - seat notes set through AX (the TextEditor's binding took it);
  - test-driven-development added from OpenRig's pool;
  - Review's rig.yaml with both startup entries;
  - `rig spec validate` valid, and preflight passed;
  - Launch brought up 2 stub seats. The notes were typed into build's pane and not review's. `.openrig/stub/skills/test-driven-development/SKILL.md` matched the spec's copy, and neither role uses that skill.
  - The rig was deleted and the spec removed.
- **Not seen:** real clicks and typing, Open File (it brings an editor to the front), the filter field, and a Claude or Codex seat's `rig skill loadout --seat` (never launched in a test).

### Blank rig and Add Seat, 2026-11-26

- **Blank rig** is "Start from: Template | Blank rig" on Start. A blank draft starts from OpenRig's empty shape (`version`, `name`, `pods: []`, `edges: []`) and Continue on Seats waits for a seat.
- **Roles** are the library's agent specs (`/api/specs/library?kind=agent`) that have a `default` profile, the one an added seat uses (`profile: default`). That leaves out `shared`, which only holds resources. An added seat names its role as `path:<agent spec folder>`.
- **Edges come from the roles.** OpenRig doesn't derive edges: a spec lists each one, per pod by member id or at rig level by `pod.member`. So New Rig learns them from the library's rig templates (`EdgeRules`). When a template has an edge from a seat of role A to a seat of role B, an added seat of role A gets that edge to every seat of role B in the rig, and the reverse. A role is its agent spec folder, so a template's `local:` ref and an added seat's `path:` ref match. Edges between seats in one pod go in the pod, and the rest at rig level, as the templates write them. Removing an added seat takes its edges with it. Edges aren't edited by hand.
- **Names:** a new seat's id and pod are the ones its role most often has in the templates (implementer gives `build` in `dev`, orchestrator `lead` in `orch`). A taken id is numbered (`build2`, `r1` → `r2`), unique across the rig, the template's removed seats included. A role no template uses is named from itself, in `dev`. A new pod gets a label (OpenRig requires one), its id capitalized.
- Seen (2026-11-26): a blank draft with four seats added from the shipped roles and templates passed `rig spec validate` and `rig up --plan`. They were orchestrator, two implementers and an independent reviewer, on stub and terminal. Lead, build, build2 and r1 landed in orch, dev, dev and review, with factory's edges. The first run found the role folder's trailing "/" kept a role from matching its templates, so every suggestion fell back. That is fixed and tested.

### New role, 2026-11-26

- **Who drafts:** the kernel's lead, `advisor-lead@kernel` (`advisor.lead` in the kernel spec). Its role is to pilot the person's intent and design topology with `openrig-architect`. The app sends the ask as a queue row (`rig queue create`, from the human seat), so it survives a restart. The body (`RoleDraft.ask`) holds the person's line, the project folder, a staging folder the app owns, the exact files and their format, and the skill ids that exist.
- **What comes back:** `agent.yaml` (name, description, defaults), `guidance/role.md`, `skills.json` (`[{id, why}]`), then an empty `READY`. The app treats these as a suggestion: `RoleDraft.read` takes the values, and a missing or malformed file is a plain failure. The app writes the agent spec itself, in the built-in roles' shape: it imports OpenRig's `shared` by `path:`, with the same plugins and runtime resources, and `guidance/role.md` as its role file.
- **Waiting:** a file-system watch on the staging folder for `READY`, plus a check of the row's state every 15 s (`rig queue show`), so a refusal shows as one. It gives up after 10 minutes, saying the ask is still queued. Cancel, Draft Again and the sheet closing each withdraw an open ask (they close the row as canceled), so the lead never holds a stale one. A quit mid-draft may not get that far, which leaves the row open until the lead reaches it, and its folder is gone then. The app never reads the lead's screen.
- **Skills:** the ones that exist are OpenRig's shared pool, the project's `.claude/skills` and `.agents/skills`, and the managed catalog (`~/.openrig/skills`). An unknown suggestion is shown struck through and never written. A ticked shared skill goes in the profile by id. A ticked project or catalog skill is copied into the role (`skills/<id>`) and declared as its own resource, so the saved role works in any rig. `rig agent validate` doesn't check skill names, so the app does.
- **Saving:** `rig agent validate` on the staged role, then `rig specs add <folder>`, which puts it in `~/.openrig/specs/<name>` and the agent library. Add Seat then lists it, and a seat is added with it as Add Seat would. A name is refused if it isn't `[a-z0-9-]`, a role already has it, or a folder in the spec library has it.
- **`OPENRIG_DEBUG_NEWROLE_DRAFT=<folder>`** (DEBUG): a prepared draft folder stands in for the kernel's lead, so a test costs no tokens.
