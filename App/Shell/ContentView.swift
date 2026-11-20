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
    @State private var detailWidth: CGFloat?
    @State private var showsQueueTask = false
    @State private var showsGoTo = false
    /// Bumped by Rig › Needs You… to open the toolbar button's list.
    @State private var needsYouRequests = 0
    @State private var fit = ToolbarFit.full
    /// The window's width beside the detail column (sidebar and inspector) while the inspector shows, so the window
    /// can't shrink until the panes overflow it and the sidebar is cut off.
    @State private var besideDetail: CGFloat?
    @State private var totalWidth: CGFloat?
    private var narrow: Bool { fit != .full }

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            RigSidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            // The toolbar belongs to the detail column, so its trailing items end at the inspector's edge
            // instead of straddling it; the inspector's toggle sits over the inspector while it shows.
            RigDetail(showsTitle: fit != .tight)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.width
                } action: { width in
                    fit = ToolbarFit(detailWidth: width)
                    detailWidth = width
                }
                .toolbar { detailToolbar }
        }
        .inspector(isPresented: inspectorBinding) {
            InspectorPanel()
                .inspectorColumnWidth(min: 260, ideal: InspectorRoom.ideal, max: 420)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) { inspectorToggle }
                }
        }
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            totalWidth = $0
        }
        .frame(minWidth: max(820, besideDetail.map { $0 + InspectorRoom.detailMinimum } ?? 0))
        .onChange(of: totalWidth) { measureBesideDetail() }
        .onChange(of: detailWidth) { measureBesideDetail() }
        .onChange(of: showsInspector) { measureBesideDetail() }
        .environment(store.selection)
        .environment(store.actions)
        .onChange(of: store.viewMode, initial: true) { old, new in
            if old != new { store.inspectorByMode[old] = wantsInspector }
            wantsInspector = store.inspectorByMode[new] ?? true
        }
        .onChange(of: store.inspectorRequests) { requestInspector() }
        .onChange(of: wantsInspector) { updateInspector() }
        .onChange(of: detailWidth) { updateInspector() }
        .focusedSceneValue(
            \.windowActions,
            WindowActions(
                queueTask: store.rig == nil || !store.isUp ? nil : { showsQueueTask = true },
                needsYou: { needsYouRequests += 1 },
                goTo: { showsGoTo = true })
        )
        .sheet(isPresented: $showsGoTo) { GoToPalette().environment(store) }
        .onChange(of: appearsActive, initial: true) { store.windowInFront = appearsActive }
        .onDisappear { store.windowInFront = false }
    }

    @ToolbarContentBuilder private var detailToolbar: some ToolbarContent {
        @Bindable var store = store
        // Centred, the picker needs room on both sides; when tight it goes leading instead.
        ToolbarItem(placement: fit == .tight ? .navigation : .principal) {
            Picker("View", selection: $store.viewMode) {
                ForEach(ViewMode.allCases) { mode in
                    Label {
                        // The shortcut, as in the design; dimmed where the control keeps text styling.
                        Text(mode.title) + Text("  \(mode.shortcutHint)").foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: mode.systemImage)
                    }
                    .labelStyle(.adaptive(iconOnly: narrow))
                    .help("\(mode.title) (\(mode.shortcutHint))")
                    .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // The toolbar keeps an item's first layout and priority: without a new identity, a window narrowed
            // after launch keeps the wide labels and everything spills into the overflow menu.
            .id(fit)
        }
        // If tight and still short, the picker overflows first: ⌘1–3 still switch views, and Needs you stays in sight.
        .keptVisible(fit != .tight)
        if let summary = store.selectedRig, !isStopped(summary) {
            ToolbarItem(placement: .primaryAction) {
                RigStopButton(summary: summary)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            // Re-identified when the badge comes or goes too: the toolbar keeps an item's first width, which cut
            // "Needs you" to "Nee…" once a count appeared.
            let badged = store.waitingEverywhere.urgent + store.waitingEverywhere.fyis > 0
            NeedsYouButton(compact: narrow, requests: needsYouRequests).id("\(narrow)-\(badged)")
        }
        .keptVisible()
        ToolbarItem(placement: .primaryAction) {
            Button("Queue task", systemImage: "plus") { showsQueueTask = true }
                .labelStyle(.adaptive(iconOnly: narrow, keepsIcon: true))
                .help("Queue task (⌘N)")
                .buttonStyle(.glassProminent)
                .disabled(store.rig == nil || !store.isUp)
                // Outside the popover, so a width change while the form is open keeps the draft.
                .id(narrow)
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

    private func measureBesideDetail() {
        guard showsInspector, let totalWidth, let detailWidth else {
            besideDetail = nil
            return
        }
        // Steady while the window resizes (the detail takes the change); it moves when a pane is resized or opens.
        let beside = (totalWidth - detailWidth).rounded()
        if abs(beside - (besideDetail ?? 0)) > 1 { besideDetail = beside }
    }

    private func updateInspector() {
        // Only opening waits for room. Hiding it as the window narrows leaves the split view stuck wider than the window.
        let shows = wantsInspector && (showsInspector || detailWidth.map(InspectorRoom.canOpen) == true)
        if showsInspector != shows { showsInspector = shows }
    }
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
enum ToolbarFit: Equatable {
    /// Labels on every item.
    case full
    /// Icons only.
    case compact
    /// Icons, no rig title, and the view picker after the sidebar toggle; it overflows first if still short.
    case tight

    init(detailWidth: CGFloat) {
        self = detailWidth >= 880 ? .full : detailWidth >= 400 ? .compact : .tight
    }
}

/// Title (with or without its icon), or icon only when space is short.
struct AdaptiveLabelStyle: LabelStyle {
    let iconOnly: Bool
    /// Icon and title when wide, rather than title only.
    var keepsIcon = false
    func makeBody(configuration: Configuration) -> some View {
        if iconOnly {
            // The system style keeps the title as the spoken name; the bare icon was read as the SF Symbol's name.
            Label(configuration).labelStyle(.iconOnly)
        } else if keepsIcon {
            // A toolbar shows any Label as its icon unless told otherwise.
            Label(configuration).labelStyle(.titleAndIcon)
        } else {
            configuration.title
        }
    }
}

extension LabelStyle where Self == AdaptiveLabelStyle {
    static func adaptive(iconOnly: Bool, keepsIcon: Bool = false) -> AdaptiveLabelStyle {
        AdaptiveLabelStyle(iconOnly: iconOnly, keepsIcon: keepsIcon)
    }
}

extension ToolbarContent {
    /// Stays in the toolbar when the window is too narrow for every item; others go to the overflow menu first.
    @ToolbarContentBuilder func keptVisible(_ kept: Bool = true) -> some ToolbarContent {
        if #available(macOS 26.1, *) {
            visibilityPriority(kept ? .high : .automatic)
        } else {
            self
        }
    }
}

// MARK: - Sidebar

struct RigSidebar: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        List(selection: $store.selectedRigID) {
            Section("Rigs") {
                ForEach(store.rigs) { rig in
                    RigRow(rig: rig).tag(rig.id)
                }
            }
        }
        .overlay {
            if store.rigs.isEmpty, store.isUp {
                ContentUnavailableView(
                    "No rigs", systemImage: "square.dashed", description: Text("Start one with rig up."))
            }
        }
        .safeAreaInset(edge: .bottom) { DaemonStatusFooter() }
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
                        .foregroundStyle(line.tone == .attention && opText == nil ? Color.lookText : .secondary)
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
            RigDot(tone: line.tone)
        }
        .help(waiting.summary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(rig.name), \(text)" + (waiting.isEmpty ? "" : ", \(waiting.summary)"))
    }

    private var opText: String? {
        switch store.rigOps[rig.id] {
        case .starting?: "starting…"
        case .stopping?: "stopping…"
        case nil: nil
        }
    }
}

/// A rig's state in its sidebar row. Orange, as on a down seat: something to look at, not a question waiting.
struct RigDot: View {
    let tone: RigLine.Tone

    var body: some View {
        Group {
            switch tone {
            case .running: Circle().fill(.green)
            case .attention: Circle().fill(.orange)
            case .stopped: Circle().strokeBorder(.secondary, lineWidth: 1.5)
            }
        }
        .frame(width: 9, height: 9)
        .accessibilityHidden(true)
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
        // `rig up` returns before the harnesses are ready, so pending seats keep the progress showing.
        if rig.op == .starting || graph.seats.contains(where: { presence($0) == .starting }) {
            let progress = startProgress(graph)
            return "Starting · \(progress.up) of \(progress.total) up"
        }
        if rig.op == .stopping { return "Stopping…" }
        if isStopped(summary) {
            return "Stopped · \(graph.seats.count) \(graph.seats.count == 1 ? "seat" : "seats")"
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
            if store.isUp, isStopped(summary), rig.op != .starting {
                StoppedRigBanner(summary: summary)
            } else if case .failed? = store.actions.status[AppStore.rigKey(summary.id)] {
                // A start or stop that failed on a rig still up: say so above the view, as the CLI put it.
                banner(tint: .orange, symbol: "power") {
                    ActionStatusLine(key: AppStore.rigKey(summary.id))
                    Spacer()
                    Button("Dismiss") { store.actions.clear(AppStore.rigKey(summary.id)) }
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
