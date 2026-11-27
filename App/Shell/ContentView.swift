import RigClient
import RigDomain
import RigModel
import SwiftUI

struct ContentView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.appearsActive) private var appearsActive
    /// What the person asked for; `showsInspector` is that, held back while the detail has no room for it.
    @State private var wantsInspector = true
    @State private var showsInspector = false
    /// Unknown until the first layout, when a restored window may be too narrow for the inspector.
    /// Hazard: not observed. As @State it re-ran `body` and rebuilt the toolbar on every point of a column
    /// animation, and the split view never settled (100% CPU after a sidebar toggle or a window resize).
    @State private var measured = Measured()
    private var detailWidth: CGFloat? { measured.detailWidth }
    @State private var showsQueueTask = false
    @State private var showsStopConfirmation = false
    @State private var showsGoTo = false
    /// Bumped by Rig › Needs You… to open the toolbar button's list.
    @State private var needsYouRequests = 0
    @State private var fit = ToolbarFit.regular
    /// The side panes' own widths, so the window can't shrink until the panes overflow it and the sidebar is cut off.
    /// Hazard: measure each pane itself. Window width minus detail width read the two a frame apart during a resize,
    /// overstated the minimum, and the window grew and re-measured until AppKit aborted the layout loop.
    @State private var sidebarWidth: CGFloat = 0
    @State private var inspectorWidth: CGFloat = 0

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            RigSidebar { summary in
                store.selectedRigID = summary.id
                // Next turn of the run loop: the toolbar's power item is rebuilt for the newly selected rig first.
                Task { @MainActor in showsStopConfirmation = true }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .onGeometryChange(for: CGFloat.self) {
                $0.size.width.rounded()
            } action: {
                sidebarWidth = $0
                debugWidths("sidebar \($0)")
            }
        } detail: {
            // The toolbar belongs to the detail column, so its trailing items end at the inspector's edge
            // instead of straddling it; the inspector's toggle sits over the inspector while it shows.
            RigDetail(showsTitle: fit != .tight)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.width
                } action: { width in
                    // A column animation jitters the width by half a point each frame.
                    guard abs(width - (measured.detailWidth ?? -1)) >= 1 else { return }
                    measured.detailWidth = width
                    let fits = ToolbarFit(detailWidth: width)
                    // Mid-drag the toolbar only narrows: the change swaps its items with a fade, and a drag
                    // back and forth over the threshold swapped them every time. It widens when the drag ends.
                    if fit != fits, !(measured.liveResize && fits < fit) { fit = fits }
                    updateInspector()
                    debugWidths("detail \(width)")
                }
                .toolbar { detailToolbar }
        }
        .inspector(isPresented: inspectorBinding) {
            InspectorPanel()
                .inspectorColumnWidth(min: 260, ideal: InspectorRoom.ideal, max: 420)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.width.rounded()
                } action: {
                    inspectorWidth = $0
                    debugWidths("inspector \($0)")
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) { inspectorToggle }
                }
        }
        .frame(minWidth: minimumWidth)
        .environment(store.selection)
        .environment(store.actions)
        .onChange(of: store.viewMode, initial: true) { old, new in
            if old != new { store.inspectorByMode[old] = wantsInspector }
            wantsInspector = store.inspectorByMode[new] ?? true
        }
        // The rig store reads a selected row it doesn't hold (closed, or another rig's) by id.
        .onChange(of: selectedRow, initial: true) { store.rig?.selectedQItemID = selectedRow.qitem }
        .onChange(of: store.inspectorRequests) { requestInspector() }
        .onChange(of: wantsInspector) { updateInspector() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willStartLiveResizeNotification)) { _ in
            measured.liveResize = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEndLiveResizeNotification)) { _ in
            measured.liveResize = false
            if let fits = detailWidth.map(ToolbarFit.init), fit != fits { fit = fits }
        }
        .focusedSceneValue(
            \.windowActions,
            WindowActions(
                queueTask: store.rig == nil || !store.isUp ? nil : { showsQueueTask = true },
                needsYou: { needsYouRequests += 1 },
                goTo: { showsGoTo = true },
                stopRig: store.selectedRig.map { !isStopped($0) && store.isUp && store.rigOps[$0.id] == nil } == true
                    ? { showsStopConfirmation = true } : nil)
        )
        .sheet(isPresented: $showsGoTo) { GoToPalette().environment(store) }
        #if DEBUG
            // OPENRIG_DEBUG_GOTO=1 opens Go To once launch has settled, for screenshots without ⌘K.
            .task {
                guard ProcessInfo.processInfo.environment["OPENRIG_DEBUG_GOTO"] == "1" else { return }
                try? await Task.sleep(for: .seconds(6))
                if !Task.isCancelled { showsGoTo = true }
            }
        #endif
        .onChange(of: appearsActive, initial: true) { store.windowInFront = appearsActive }
        .onDisappear { store.windowInFront = false }
    }

    @ToolbarContentBuilder private var detailToolbar: some ToolbarContent {
        @Bindable var store = store
        // Centred, the picker needs room on both sides; when tight it goes leading instead.
        ToolbarItem(placement: fit == .tight ? .navigation : .principal) {
            Picker("View", selection: $store.viewMode) {
                ForEach(ViewMode.allCases) { mode in
                    // Icons at every width: a label that came and went with the width re-made the item, with a fade.
                    Label(mode.title, systemImage: mode.systemImage)
                        .labelStyle(.iconOnly)
                        .help("\(mode.title) (\(mode.shortcutHint))")
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        // If tight and still short, the picker overflows first: ⌘1–3 still switch views, and Needs you stays in sight.
        .keptVisible(fit != .tight)
        if let summary = store.selectedRig {
            ToolbarItem(placement: .primaryAction) {
                RigPowerButton(summary: summary, confirmingStop: $showsStopConfirmation)
            }
            // Its own glass group: a stop control shouldn't share a capsule with Needs you.
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        ToolbarItem(placement: .primaryAction) {
            // Re-identified when the badge comes or goes: the toolbar keeps an item's first width, which cut
            // the button short once a count appeared.
            let badged = store.waitingEverywhere.urgent + store.waitingEverywhere.fyis > 0
            NeedsYouButton(requests: needsYouRequests).id(badged)
        }
        .keptVisible()
        ToolbarItem(placement: .primaryAction) {
            Button("Queue task", systemImage: "plus") { showsQueueTask = true }
                .labelStyle(.iconOnly)
                .help("Queue task (⌘N)")
                .buttonStyle(.glassProminent)
                .disabled(store.rig == nil || !store.isUp)
                .popover(isPresented: $showsQueueTask, arrowEdge: .bottom) {
                    if let rig = store.rig {
                        QueueTaskForm(
                            rig: rig, preselected: rig.seat(store.selection.seatID)?.sessionName,
                            done: { showsQueueTask = false }
                        )
                        .environment(store.actions)
                    }
                }
        }
        .keptVisible()
    }

    private var inspectorToggle: some View {
        Button("Inspector", systemImage: "sidebar.right") { inspectorBinding.wrappedValue.toggle() }
            .help(showsInspector ? "Hide Inspector (⌃⌘I)" : "Show Inspector (⌃⌘I)")
    }

    /// The toggle, ⌃⌘I and the system's own close all come through here.
    private var inspectorBinding: Binding<Bool> {
        Binding(get: { showsInspector }, set: { $0 ? requestInspector() : (wantsInspector = false) })
    }

    private func requestInspector() {
        wantsInspector = true
        guard !showsInspector, let detailWidth, !InspectorRoom.canOpen(detailWidth: detailWidth) else { return }
        // Asked for in a narrow window: widen it, as Xcode does, and show the inspector once there is room.
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, let screen = window.screen?.visibleFrame else { return }
        var frame = window.frame
        frame.size.width = min(frame.width + InspectorRoom.needed - detailWidth, screen.width)
        frame.origin.x = min(frame.minX, screen.maxX - frame.width)
        window.setFrame(frame, display: true, animate: true)
    }

    private var selectedRow: SelectedRow {
        SelectedRow(rig: store.rig.map(ObjectIdentifier.init), qitem: store.selection.qitemID)
    }

    /// Grows while the inspector shows. Steady while the window resizes: the detail takes the change.
    private var minimumWidth: CGFloat {
        guard showsInspector, inspectorWidth > 0 else { return 820 }
        return max(820, sidebarWidth + inspectorWidth + InspectorRoom.detailMinimum)
    }

    /// OPENRIG_DEBUG_WIDTHS=<file>: one line per width measurement, to find a resize feedback loop.
    private func debugWidths(_ change: String) {
        #if DEBUG
            guard let path = ProcessInfo.processInfo.environment["OPENRIG_DEBUG_WIDTHS"] else { return }
            let w = { (v: CGFloat?) in v.map { "\(Int($0))" } ?? "-" }
            let line =
                "\(Date.now.timeIntervalSince1970) [\(change)] sidebar \(Int(sidebarWidth)) detail \(w(detailWidth))"
                + " inspector \(Int(inspectorWidth)) \(showsInspector) min \(Int(minimumWidth)) fit \(fit)\n"
            if let handle = FileHandle(forWritingAtPath: path) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(toFile: path, atomically: true, encoding: .utf8)
            }
        #endif
    }

    private func updateInspector() {
        // Only opening waits for room. Hiding it as the window narrows leaves the split view stuck wider than the window.
        let shows = wantsInspector && (showsInspector || detailWidth.map(InspectorRoom.canOpen) == true)
        if showsInspector != shows { showsInspector = shows }
    }
}

/// The selected qitem in a given rig store: a new store (rig switched or rebuilt) is told again.
private struct SelectedRow: Equatable {
    var rig: ObjectIdentifier?
    var qitem: QItem.ID?
}

/// Layout readings kept out of observed state.
private final class Measured {
    var detailWidth: CGFloat?
    /// The person is dragging a window edge.
    var liveResize = false
}

/// Whether the inspector can open beside the detail column.
///
/// Hazard: a window restored narrower than sidebar + inspector ideal + the split view's detail minimum (about 330 pt)
/// with the inspector shown makes SwiftUI loop on constraints and abort ("more Update Constraints in Window passes
/// than there are views"), on every launch. So the inspector opens only after the first layout, and only with room.
enum InspectorRoom {
    static let ideal: CGFloat = 320
    /// The narrowest the detail column gets beside the inspector, about the split view's own minimum.
    static let detailMinimum: CGFloat = 340
    /// Detail width, without the inspector, needed to open it: the inspector's ideal plus room for the detail.
    static let needed: CGFloat = ideal + detailMinimum

    static func canOpen(detailWidth: CGFloat) -> Bool { detailWidth >= needed }
}

/// How much of the toolbar fits over the detail column; the inspector's toolbar sits over the inspector.
/// Ordered widest first.
enum ToolbarFit: Comparable {
    case regular
    /// No rig title, and the view picker after the sidebar toggle; it overflows first if still short.
    case tight

    init(detailWidth: CGFloat) {
        self = detailWidth >= 400 ? .regular : .tight
    }
}

extension ToolbarContent {
    /// Stays in the toolbar when the window is too narrow for every item; others go to the overflow menu first.
    func keptVisible(_ kept: Bool = true) -> some ToolbarContent {
        visibilityPriority(kept ? .high : .automatic)
    }
}

// MARK: - Sidebar

struct RigSidebar: View {
    /// Opens the window's own stop confirmation for a rig, so a stop from here names who is mid-turn as the
    /// toolbar's does.
    let stopRig: (RigSummary) -> Void
    @Environment(AppStore.self) private var store
    @State private var removing: Removal?

    var body: some View {
        @Bindable var store = store
        List(selection: $store.selectedRigID) {
            Section("Rigs") {
                ForEach(store.rigs) { rig in
                    RigRow(rig: rig).tag(rig.id)
                        .contextMenu { menu(for: rig) }
                }
            }
        }
        .confirmationDialog(
            removing?.title ?? "", isPresented: removingBinding, titleVisibility: .visible, presenting: removing
        ) { removal in
            Button(removal.button, role: removal.kind == .delete ? .destructive : nil) {
                Task {
                    switch removal.kind {
                    case .archive: await store.archiveRig(removal.rig)
                    case .delete: await store.deleteRig(removal.rig)
                    }
                }
            }
        } message: { removal in
            Text(removal.message)
        }
        .overlay {
            if store.rigs.isEmpty, store.isUp {
                ContentUnavailableView(
                    "No rigs", systemImage: "square.dashed", description: Text("Start one with rig up."))
            }
        }
        .safeAreaInset(edge: .bottom) { DaemonStatusFooter() }
    }

    /// Acts on the row's rig, which need not be the selected one. Items that ask first select the rig, so the
    /// confirmation and the result show on the rig they're about.
    @ViewBuilder private func menu(for rig: RigSummary) -> some View {
        let busy = store.rigOps[rig.id] != nil || !store.isUp
        if isStopped(rig) {
            Button("Start Rig", systemImage: "power") { Task { await store.startRig(rig) } }
                .disabled(busy)
        } else {
            Button("Stop Rig…", systemImage: "power") { stopRig(rig) }
                .disabled(busy)
        }
        Divider()
        let removable = store.canRemove(rig)
        let why = isStopped(rig) ? nil : "Stop the rig first"
        Button("Archive Rig…", systemImage: "archivebox") { ask(.archive, rig) }
            .disabled(!removable)
            .help(why ?? RigAction.rigArchive(rig: rig.name).userCommand)
        Button("Delete Rig…", systemImage: "trash", role: .destructive) { ask(.delete, rig) }
            .disabled(!removable)
            .help(why ?? RigAction.rigDelete(rig: rig.name).userCommand)
    }

    private func ask(_ kind: Removal.Kind, _ rig: RigSummary) {
        store.selectedRigID = rig.id
        removing = Removal(kind: kind, rig: rig)
    }

    private var removingBinding: Binding<Bool> {
        Binding {
            removing != nil
        } set: {
            if !$0 { removing = nil }
        }
    }
}

/// An archive or delete waiting on the person's confirmation.
private struct Removal {
    enum Kind { case archive, delete }
    let kind: Kind
    let rig: RigSummary

    var title: String {
        switch kind {
        case .archive: "Archive \(rig.name)?"
        case .delete: "Delete \(rig.name)?"
        }
    }

    var button: String {
        switch kind {
        case .archive: "Archive Rig"
        case .delete: "Delete Rig"
        }
    }

    var message: String {
        switch kind {
        case .archive:
            "It's hidden from the rig list and keeps all its data. Bring it back with "
                + "rig unarchive \(rig.name)."
        case .delete:
            "Its rig record is removed, so Start Rig can't bring it back.\n\n"
                + RigAction.rigDelete(rig: rig.name).userCommand
        }
    }
}

struct RigRow: View {
    let rig: RigSummary
    @Environment(AppStore.self) private var store

    var body: some View {
        let waiting = store.waiting(in: rig)
        let line = rigLine(rig)
        let text = opText ?? line.text
        Label {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(rig.name)
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(captionColor(line.tone))
                        .monospacedDigit()
                }
                Spacer()
                // Coral for what waits on an answer, as on the toolbar's Needs you; grey when only FYIs wait.
                let selected = store.selectedRigID == rig.id
                if waiting.urgent > 0 {
                    CountBadge(count: waiting.urgent, onSelection: selected)
                } else if waiting.fyis > 0 {
                    CountBadge(count: waiting.fyis, quiet: true, onSelection: selected)
                }
            }
        } icon: {
            RigDot(tone: line.tone, busy: store.rigOps[rig.id])
        }
        .help(waiting.summary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(rig.name), \(text)" + (waiting.isEmpty ? "" : ", \(waiting.summary)"))
    }

    private func captionColor(_ tone: RigLine.Tone) -> Color {
        guard opText == nil else { return .secondary }
        switch tone {
        case .attention: return .lookText
        case .needsYou: return .attention
        case .running, .stopped: return .secondary
        }
    }

    private var opText: String? {
        switch store.rigOps[rig.id] {
        case .starting?: "starting…"
        case .stopping?: "stopping…"
        case nil: nil
        }
    }
}

/// A rig's state in its sidebar row. Orange, as on a down seat: something to look at. Coral, as on a seat: it
/// needs you.
struct RigDot: View {
    let tone: RigLine.Tone
    /// A start or stop in flight: a ring, as on a starting seat.
    var busy: RigOp?

    var body: some View {
        Group {
            if let busy {
                Circle().strokeBorder(busy == .starting ? Color.green : .secondary, lineWidth: 1.5)
            } else {
                dot
            }
        }
        .frame(width: 9, height: 9)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var dot: some View {
        switch tone {
        case .running: Circle().fill(.green)
        case .attention: Circle().fill(.orange)
        case .needsYou: Circle().fill(Color.attention)
        case .stopped: Circle().strokeBorder(.secondary, lineWidth: 1.5)
        }
    }
}

struct DaemonStatusFooter: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 6) {
            switch store.daemon {
            case .connecting:
                ProgressView().controlSize(.small)
                Text("Connecting…")
            case .running(let health):
                HStack(spacing: 6) {
                    Image(systemName: health.isHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(health.isHealthy ? .green : .orange)
                    Text("Daemon \(health.semver ?? "")")
                    if !store.isLive {
                        Text("· polling").foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityLabel(
                    "Daemon \(health.semver ?? ""), \(health.isHealthy ? "running" : "running with problems")"
                        + (store.isLive ? "" : ", polling")
                )
                .help(footerHelp)
            case .unreachable(_, let since):
                HStack(spacing: 6) {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(Color.attention)
                    if store.canStartDaemon {
                        Text("Daemon stopped · since \(since, style: .time)")
                    } else {
                        Text("Can't reach \(store.daemonAddress)")
                    }
                }
                .accessibilityElement(children: .combine)
                .help(footerHelp)
                Spacer(minLength: 4)
                if store.canStartDaemon {
                    Button("Start") { Task { await store.startDaemon() } }
                        .controlSize(.small)
                        .disabled(store.actions.isRunning("daemon"))
                        .help("rig daemon start")
                } else {
                    ConnectionSettingsButton(title: "Settings…").controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footerHelp: String {
        switch store.daemon {
        case .unreachable(let reason, _): "\(store.endpoint.baseURL.absoluteString): \(reason)"
        default: store.endpoint.baseURL.absoluteString
        }
    }
}

// MARK: - Detail

struct RigDetail: View {
    /// Off when the toolbar is tight, to leave room for the view picker; the sidebar still shows the rig.
    var showsTitle = true
    @Environment(AppStore.self) private var store

    var body: some View {
        Group {
            if let rig = store.rig, let summary = store.selectedRig {
                Group {
                    switch store.viewMode {
                    case .canvas:
                        CanvasView()
                    case .queue:
                        QueueBoardView()
                    case .terminals:
                        TerminalsView()
                    }
                }
                .environment(rig)
                // Offline, the last data stays on screen, dimmed, with when it was current. A stopped rig isn't
                // dimmed: dimming took its text below 3:1; its banner and stopped seats say it isn't live.
                .opacity(store.isUp ? 1 : 0.55)
                .safeAreaInset(edge: .top, spacing: 0) { StatusBanners(rig: rig, summary: summary) }
                .navigationTitle(summary.name)
                .navigationSubtitle(subtitle(rig, summary))
                .toolbar(removing: showsTitle ? nil : .title)
            } else if case .unreachable(let reason, _) = store.daemon {
                // Named for what can fix it: start a local daemon, or check the address someone set.
                ContentUnavailableView {
                    Label(
                        store.canStartDaemon ? "Daemon not running" : "Can't reach the daemon",
                        systemImage: "bolt.horizontal.circle")
                } description: {
                    Text("\(store.daemonAddress): \(reason)")
                } actions: {
                    HStack {
                        if store.canStartDaemon {
                            Button("Start Daemon") { Task { await store.startDaemon() } }
                                .buttonStyle(.borderedProminent)
                                .disabled(store.actions.isRunning("daemon"))
                                .help("rig daemon start")
                        }
                        Button("Retry") { Task { await store.refreshNow() } }
                        ConnectionSettingsButton(title: "Connection Settings…")
                    }
                    // The view gives every action the same width; that truncated "Connection Settings…".
                    .fixedSize()
                    ActionStatusLine(key: "daemon")
                }
            } else {
                ContentUnavailableView("Select a rig", systemImage: "circle.hexagongrid")
            }
        }
    }

    private func subtitle(_ rig: RigStore, _ summary: RigSummary) -> String {
        guard let graph = rig.graph else { return "" }
        // `rig up` returns before the harnesses are ready, so pending seats keep the progress showing. One seat
        // relaunching (Resume Seat, Start Fresh) is named; a rig-wide count would read as the whole rig starting.
        let starting = graph.seats.filter { presence($0) == .starting }
        if rig.op == nil, starting.count == 1, let seat = starting.first { return "Starting \(seat.displayName)" }
        if rig.op == .starting || !starting.isEmpty {
            let progress = startProgress(graph)
            return "Starting · \(progress.up) of \(progress.total) up"
        }
        if rig.op == .stopping { return "Stopping…" }
        if isStopped(summary) {
            return "Stopped · \(graph.seats.count) \(graph.seats.count == 1 ? "seat" : "seats")"
        }
        // Degraded or waiting on the person: say what the sidebar says.
        let line = rigLine(summary)
        if line.tone == .attention || line.tone == .needsYou {
            return "\(line.text.prefix(1).uppercased())\(line.text.dropFirst()) · \(store.isLive ? "live" : "polling")"
        }
        let working = graph.seats.filter { SeatPhase($0) == .working }.count
        return
            "\(graph.seats.count) \(graph.seats.count == 1 ? "seat" : "seats") · \(working) working · \(store.isLive ? "live" : "polling")"
    }
}

struct InspectorPanel: View {
    @Environment(AppStore.self) private var store
    @Environment(SelectionStore.self) private var selection

    var body: some View {
        Group {
            if let rig = store.rig {
                content(rig).environment(rig)
            } else {
                empty
            }
        }
    }

    // The Queue board inspects qitems; the canvas inspects whatever was selected last.
    @ViewBuilder private func content(_ rig: RigStore) -> some View {
        let wantsItem = store.viewMode == .queue || selection.inspecting == .qitem
        if wantsItem, let item = rig.item(selection.qitemID) {
            QItemInspector(item: item).id(item.id)
        } else if let graph = rig.graph, let seat = rig.seat(selection.seatID) {
            SeatInspector(seat: seat, graph: graph).id(seat.id)
        } else {
            empty
        }
    }

    private var empty: some View {
        ContentUnavailableView(
            "No selection", systemImage: "cursorarrow.click",
            description: Text(store.viewMode == .queue ? "Select a qitem." : "Select a seat."))
    }
}

/// Daemon-down and untested-version notices above the current view.
struct StatusBanners: View {
    let rig: RigStore
    let summary: RigSummary
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            if store.isUp, isStopped(summary) {
                StoppedRigBanner(summary: summary)
            } else if let failed = store.failedOps[summary.id],
                case .failed? = store.actions.status[AppStore.rigKey(summary.id)]
            {
                // A start or stop that failed on a rig still up: which one, the CLI's reason, and a retry.
                banner(tint: .orange, symbol: "power") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Couldn't \(failed == .starting ? "start" : "stop") \(summary.name).").font(.headline)
                        ActionStatusLine(key: AppStore.rigKey(summary.id))
                    }
                    Spacer()
                    Button("Try Again") { Task { await store.retry(summary) } }
                        .disabled(store.rigOps[summary.id] != nil)
                    Button("Dismiss") { store.dismissFailure(summary.id) }
                }
            }
            if case .unreachable(let reason, _) = store.daemon {
                banner(tint: .attention, symbol: "bolt.horizontal.circle") {
                    Text("Daemon stopped. Showing data from \(stale), read-only.")
                        .help(reason)
                    Spacer()
                    ActionStatusLine(key: "daemon")
                    Button("Start daemon") { Task { await store.startDaemon() } }
                        .disabled(store.actions.isRunning("daemon"))
                        .help("rig daemon start")
                    Button("Retry") { Task { await store.refreshNow() } }
                }
            }
            if case .running(let health) = store.daemon, case .untested(let version) = health.compatibility {
                banner(tint: .orange, symbol: "exclamationmark.triangle") {
                    Text(
                        "Daemon \(version) is untested. This app was built against rig \(DaemonHealth.testedMinor.major).\(DaemonHealth.testedMinor.minor).x; some views may be wrong."
                    )
                    Spacer()
                }
            }
        }
    }

    private var stale: String {
        guard let at = rig.lastUpdated else { return "before the outage" }
        return at.formatted(date: .omitted, time: .shortened)
    }

    private func banner(tint: Color, symbol: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            content()
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(tint.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Opens Settings on the Connection tab, where the daemon's address and token are.
struct ConnectionSettingsButton: View {
    let title: String
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button(title) {
            // SettingsView keeps its tab in this key (@AppStorage), so set it before the window opens.
            UserDefaults.standard.set(SettingsView.Pane.connection.rawValue, forKey: "settingsPane")
            openSettings()
        }
    }
}
