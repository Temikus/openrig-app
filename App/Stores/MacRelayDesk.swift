import Foundation
import RigClient
import RigDomain
import RigModel
import RigTerminal

/// The relay's desk on the Mac: what the phone may see and do, read and run the way the app's own controls do.
/// Prompts are re-read from the daemon and the pane, actions go through ActionStore as the app's person.
@MainActor
final class MacRelayDesk: RelayDesk {
    private weak var store: AppStore?

    init(store: AppStore) {
        self.store = store
    }

    private var client: DaemonHTTP? {
        store.map { DaemonHTTP(baseURL: $0.endpoint.baseURL, timeout: 5, bearer: $0.token) }
    }

    // MARK: Needs you

    func needsYou() async -> RelayNeedsYou {
        guard let store else { return RelayNeedsYou() }
        let me = store.me
        var items: [RelayNeedsYouItem] = []
        if let rig = store.rig {
            for entry in rig.needsYou {
                switch entry {
                case .prompt(let prompt, _):
                    items.append(
                        RelayNeedsYouItem(
                            kind: "prompt", id: entry.id, rig: rig.rigName,
                            title: "\(rig.displayName(session: prompt.session)) asks to run", detail: prompt.command,
                            session: prompt.session))
                case .seat(let seat, _):
                    items.append(
                        RelayNeedsYouItem(
                            kind: "seat", id: entry.id, rig: rig.rigName, title: "\(seat.displayName) is down",
                            session: seat.sessionName))
                case .qitem(let row):
                    items.append(Self.item(row, rig: rig.rigName, me: me))
                }
            }
        }
        let shown = Set(items.compactMap(\.row))
        for row in store.elsewhere where !shown.contains(row.id) {
            items.append(Self.item(row, rig: Self.rig(of: row.source), me: me))
        }
        // Other rigs' prompts and down seats, as the Mac's sidebar counts them; each is on that rig's seat list.
        let elsewhere = store.attentionElsewhere.map { RelayNeedsYou.RigCount(rig: $0.rig, count: $0.count) }
        return RelayNeedsYou(items: items, promptsElsewhere: elsewhere)
    }

    private static func item(_ row: QItem, rig: String, me: String) -> RelayNeedsYouItem {
        let kind: String =
            if case .blocked(on: .outside) = workStatus(row) {
                "held"
            } else if row.asksHuman || forYou(row, me: me) == .decision {
                "ask"
            } else {
                "fyi"
            }
        return RelayNeedsYouItem(
            kind: kind, id: "qitem:\(row.id)", rig: rig, title: row.summary, session: row.source, row: row.id)
    }

    private static func rig(of session: String) -> String {
        session.split(separator: "@").dropFirst().first.map(String.init) ?? ""
    }

    // MARK: Prompts

    /// The seat with this session, from the open rig's graph or any rig's.
    private func seat(_ session: String) async -> Seat? {
        if let seat = store?.rig?.seat(session: session) { return seat }
        guard let store, let client else { return nil }
        for rig in store.rigs where !rig.isArchived {
            if let seat = try? await client.graph(rigID: rig.id).seats.first(where: { $0.sessionName == session }) {
                return seat
            }
        }
        return nil
    }

    private func screen(_ seat: Seat) async -> PromptScreen? {
        guard let pane = seat.tmuxPane, let lines = try? await store?.tmux()?.screen(pane: pane) else { return nil }
        return PromptScreen(lines: lines)
    }

    func prompt(session: String) async -> RelayPromptReading? {
        guard let seat = await seat(session), let client,
            let stop = try? await client.seatStatus(session: session).permissionStop,
            let prompt = PromptInstance(seat: seat, stop: stop)
        else { return nil }
        // The pane gives the full command and the menu's own keys; without it, no key is guessed.
        let screen = await screen(seat)
        return RelayPromptReading(
            session: session, seatName: seat.displayName, command: screen?.command ?? prompt.command,
            observedAt: prompt.observedAt.map { Self.time.format($0) } ?? "", allowOnceKey: screen?.allowOnceKey,
            declineKey: screen?.declineKey)
    }

    /// The same moment always formats to the same text, so the phone's echo compares equal only for the same stop.
    private static let time = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    func waitForNoPrompt(session: String) async -> (paneClear: Bool, daemonHolds: Bool) {
        guard let seat = await seat(session) else { return (false, false) }
        var clear = false
        for _ in 0..<10 {
            if await screen(seat) == nil {
                clear = true
                break
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        let stop = try? await client?.seatStatus(session: session).permissionStop
        return (clear, stop?.state == .requestObserved)
    }

    /// The row the Mac's prompt control resolves: the seat's linked row (`PromptInstance.linkedQItem`, in-progress
    /// first), and only if it's parked on a person. Called after the answer, when the daemon's stop may be gone, so
    /// the instance is built from a stand-in stop; `linkedQItem` reads only the session and the rows.
    func heldRow(session: String) async -> String? {
        guard let seat = await seat(session),
            let instance = PromptInstance(seat: seat, stop: PermissionStop(state: .requestObserved, command: "-"))
        else { return nil }
        let rows: [QItem]
        if let open = store?.rig, open.seat(session: session) != nil {
            rows = open.items
        } else {
            rows = (try? await client?.queue(rigName: Self.rig(of: session))) ?? []
        }
        guard let linked = instance.linkedQItem(in: rows), case .blocked(on: .outside) = workStatus(linked) else {
            return nil
        }
        return linked.id
    }

    func isForPerson(_ row: QItem) async -> Bool {
        guard let me = store?.me else { return false }
        return forYou(row, me: me) != nil
    }

    /// The Mac acts as its own person. A phone paired on this daemon to answer as someone else must not act through
    /// it, so every action is refused until that phone is paired again. The relay can't tell which phone is
    /// calling (Network doesn't expose the negotiated PSK identity), hence the whole set.
    func refusesActing() async -> String? {
        guard let store else { return "The Mac app isn't ready." }
        let phones = PairedPhones(data: UserDefaults.standard.data(forKey: "pairedPhones"))
            .list(for: store.endpoint.baseURL)
        guard let other = phones.first(where: { $0.actor != store.me }) else { return nil }
        return "This Mac now acts as \(store.me), but a phone was paired to answer as \(other.actor). Pair it again."
    }

    // MARK: Rows, rigs, seats

    func row(_ id: String) async -> QItem? {
        if let row = store?.rig?.item(id) ?? store?.elsewhere.first(where: { $0.id == id }) { return row }
        return try? await client?.qitem(id: id)
    }

    func rigs() async -> [RelayRig] {
        (store?.rigs ?? []).filter { !$0.isArchived }.map {
            RelayRig(id: $0.id, name: $0.name, state: $0.lifecycle.rawValue, seats: $0.nodeCount)
        }
    }

    func seats(rig name: String) async -> [RelaySeat]? {
        guard let summary = store?.rigs.first(where: { $0.name == name }), let client,
            let graph = try? await client.graph(rigID: summary.id)
        else { return nil }
        let rows = (try? await client.queue(rigName: name)) ?? []
        // Each Claude seat's own daemon stop, for whichever rig is asked: not only the one open on the Mac.
        let sessions = graph.seats.filter { $0.runtime == "claude-code" }.compactMap(\.sessionName)
        let atPrompt = await withTaskGroup(of: (String, Bool).self) { group in
            for session in sessions {
                group.addTask {
                    let stop = try? await client.seatStatus(session: session).permissionStop
                    return (session, stop?.state == .requestObserved)
                }
            }
            var found: Set<String> = []
            for await (session, waiting) in group where waiting { found.insert(session) }
            return found
        }
        return graph.seats.compactMap { seat in
            guard let session = seat.sessionName else { return nil }
            let mine = rows.filter { $0.destination == session && workStatus($0).isActive }
            let blocked = mine.filter { if case .blocked = workStatus($0) { true } else { false } }
            let current = mine.first { workStatus($0) == .inProgress } ?? mine.first
            return RelaySeat(
                session: session, name: seat.displayName, state: seat.status.rawValue, currentRow: current?.summary,
                active: mine.count, blocked: blocked.count,
                contextUsed: seat.contextUsedPercent.map { Double($0) / 100 },
                runtime: seat.runtime, atPrompt: atPrompt.contains(session))
        }
    }

    // MARK: Actions

    /// Runs as the app's person, through the same ActionStore as the Mac's buttons.
    func perform(_ action: RigAction) async -> RelayOutcome {
        guard let actions = store?.actions else { return .failed("The Mac app isn't ready.") }
        let key = "relay:\(UUID().uuidString)"
        defer { actions.clear(key) }
        if await actions.perform(action, key: key, success: "Done from the phone") { return .done }
        if case .failed(let message) = actions.status[key] { return .failed(message) }
        return .failed("The action didn't finish.")
    }
}
