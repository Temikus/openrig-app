import RigClient
import RigModel
import SwiftUI

/// The Rigs tab's data, read through the session's relay client (`RemoteSession.desk`). Board 6B: rigs first, then a
/// rig's seats.
@MainActor @Observable
final class RigsStore {
    private(set) var client: RelayDeskClient?

    var rigs: [RelayRig]?
    var seats: [String: [RelaySeat]] = [:]
    /// The command a seat at a prompt asks to run, by session.
    var prompts: [String: String] = [:]
    /// The last read that failed, in words. Cleared by the next one that works.
    var readError: String?
    /// Drafts by session, kept until sent.
    var messageDrafts: [String: String] = [:]
    var taskDrafts: [String: (summary: String, body: String)] = [:]
    /// What the last message or task did, by session.
    var results: [String: SendResult] = [:]

    struct SendResult: Equatable {
        var ok: Bool
        var words: String
    }

    /// Takes the session's client. Another client means another pairing or address: drop what the old one read.
    func use(_ desk: RelayDeskClient?) {
        guard desk !== client else { return }
        client = desk
        rigs = nil
        seats = [:]
        prompts = [:]
        results = [:]
    }

    func seat(_ session: String) -> RelaySeat? {
        seats.values.lazy.flatMap { $0 }.first { $0.session == session }
    }

    /// Results are written only while `client` is still the one that asked. A reply from a replaced client (another
    /// pairing or address) would show the old Mac's rigs until the next poll.
    private func current(_ asked: RelayDeskClient) -> Bool { client === asked }

    func loadRigs(macName: String) async {
        guard let client else { return }
        do {
            let list = try await client.rigs()
            guard current(client) else { return }
            rigs = list
            readError = nil
        } catch {
            if current(client) { note(error, macName: macName) }
        }
    }

    func loadSeats(rig: String, macName: String) async {
        guard let client else { return }
        do {
            let list = try await client.seats(rig: rig)
            guard current(client) else { return }
            seats[rig] = list
            readError = nil
            for seat in list where seat.atPrompt && prompts[seat.session] == nil {
                let command = try? await client.prompt(session: seat.session).command
                guard current(client) else { return }
                prompts[seat.session] = command
            }
            for seat in list where !seat.atPrompt { prompts[seat.session] = nil }
        } catch {
            if current(client) { note(error, macName: macName) }
        }
    }

    private func note(_ error: RelayDeskError, macName: String) {
        switch error {
        case .cancelled: break  // the screen went away
        case .unreachable, .lostReply: readError = "Can't reach \(macName). This is what it showed last."
        case .notFound(let message): readError = message
        default: readError = "\(macName) couldn't show this. Update OpenRig on the Mac."
        }
    }

    func message(_ text: String, to seat: RelaySeat) async {
        guard let client else { return }
        let send = RemoteSend.message(to: seat.name)
        do {
            try await client.message(session: seat.session, text: text)
            guard current(client) else { return }
            messageDrafts[seat.session] = nil
            results[seat.session] = SendResult(ok: true, words: send.done)
        } catch {
            if current(client) { results[seat.session] = SendResult(ok: false, words: send.words(for: error)) }
        }
    }

    func task(summary: String, body: String, for seat: RelaySeat) async {
        guard let client else { return }
        let send = RemoteSend.task(for: seat.name)
        do {
            try await client.task(session: seat.session, summary: summary, body: body)
            guard current(client) else { return }
            taskDrafts[seat.session] = nil
            results[seat.session] = SendResult(ok: true, words: send.done)
        } catch {
            if current(client) { results[seat.session] = SendResult(ok: false, words: send.words(for: error)) }
        }
    }
}

/// Where the Rigs tab's stack is: a rig, then a seat in it.
enum RigsLink: Hashable {
    case rig(String)
    case seat(rig: String, session: String)
}

/// Rigs first, each with what waits in it; a rig opens its seats (board 6B).
struct RigsView: View {
    @Environment(RemoteSession.self) private var model
    @State private var store = RigsStore()
    @State private var path: [RigsLink] = []

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Rigs")
                .toolbar { ToolbarItem(placement: .largeSubtitle) { MacLine() } }
                .refreshable { await store.loadRigs(macName: model.macName) }
                .navigationDestination(for: RigsLink.self) { link in
                    switch link {
                    case .rig(let name): RigScreen(rig: name)
                    case .seat(let rig, let session): SeatScreen(rig: rig, session: session)
                    }
                }
        }
        .environment(store)
        .onAppear {
            store.use(model.desk)
            #if DEBUG
                if path.isEmpty { path = RigsLink.launchPath }
            #endif
        }
        .onChange(of: model.desk.map(ObjectIdentifier.init)) { store.use(model.desk) }
        // Restarts with each new client, so the first read follows the session's first connection.
        .task(id: model.desk.map(ObjectIdentifier.init)) {
            while !Task.isCancelled {
                await store.loadRigs(macName: model.macName)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Mac-side calls only go through the relay, which a pairing without a Wi-Fi reach never uses.
    var viaRelay: Bool { model.pairing?.code.reaches.contains { $0.kind == .lan } == true }

    @ViewBuilder var content: some View {
        if !viaRelay {
            ContentUnavailableView {
                Label("Rigs need the Wi-Fi link", systemImage: "wifi.slash")
            } description: {
                Text(
                    "This phone was paired without the Mac's Wi-Fi link, which the Rigs tab uses. Pair again with the code from OpenRig on the Mac, under Settings, Phone."
                )
            }
        } else if let rigs = store.rigs {
            List {
                if let readError = store.readError { ReadErrorRow(words: readError) }
                ForEach(rigs, id: \.id) { rig in
                    NavigationLink(value: RigsLink.rig(rig.name)) {
                        // The session reads the relay's Needs-you list on each check.
                        RigRow(rig: rig, waiting: model.relayNeeds?.waiting(in: rig.name) ?? 0)
                    }
                }
            }
            .overlay {
                if rigs.isEmpty {
                    ContentUnavailableView("No rigs", systemImage: "square.stack.3d.up.slash")
                }
            }
        } else if let readError = store.readError {
            ContentUnavailableView {
                Label("Can't show rigs", systemImage: "wifi.exclamationmark")
            } description: {
                Text(readError)
            }
        } else if store.client == nil, let status = model.status, !isConnected(status) {
            // The session has no client until it reaches the Mac; Needs you says why in full.
            ContentUnavailableView {
                Label("Can't reach \(model.macName)", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Rigs show once this phone reaches \(model.macName) on the Wi-Fi. Needs you says what's wrong.")
            }
        } else {
            ProgressView("Asking \(model.macName)…")
        }
    }

    func isConnected(_ status: RemoteStatus) -> Bool {
        if case .connected = status { true } else { false }
    }
}

/// A rig's name and seat count, with what waits in it as a badge (board 6, B1).
struct RigRow: View {
    var rig: RelayRig
    var waiting: Int

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(rig.name).font(.headline)
                Text(caption).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if waiting > 0 {
                Text("\(waiting)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .frame(minWidth: 24, minHeight: 24)
                    .background(Color.statusBad, in: .capsule)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(waiting > 0 ? "\(waiting) waiting on you" : "")
    }

    var caption: String {
        let seats = rig.seats == 1 ? "1 seat" : "\(rig.seats) seats"
        return rig.state == "running" ? seats : "\(seats) · \(rig.state)"
    }
}

/// A banner for a read that failed, over what was shown last.
struct ReadErrorRow: View {
    var words: String

    var body: some View {
        Label {
            Text(words)
        } icon: {
            Image(systemName: "wifi.exclamationmark").foregroundStyle(Color.statusBad)
        }
        .font(.subheadline)
    }
}

/// One rig's seats, each with its state (board 6, B2).
struct RigScreen: View {
    @Environment(RemoteSession.self) private var model
    @Environment(RigsStore.self) private var store
    var rig: String

    var body: some View {
        content
            .navigationTitle(rig)
            .toolbar {
                if let seats = store.seats[rig] {
                    ToolbarItem(placement: .largeSubtitle) {
                        Text(RelaySeat.summary(seats))
                            .font(.subheadline).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .refreshable { await store.loadSeats(rig: rig, macName: model.macName) }
            .task {
                while !Task.isCancelled {
                    await store.loadSeats(rig: rig, macName: model.macName)
                    try? await Task.sleep(for: .seconds(5))
                }
            }
    }

    @ViewBuilder var content: some View {
        if let seats = store.seats[rig] {
            List {
                if let readError = store.readError { ReadErrorRow(words: readError) }
                ForEach(seats, id: \.session) { seat in
                    NavigationLink(value: RigsLink.seat(rig: rig, session: seat.session)) { SeatRow(seat: seat) }
                }
            }
        } else if let readError = store.readError {
            ContentUnavailableView {
                Label("Can't show \(rig)", systemImage: "wifi.exclamationmark")
            } description: {
                Text(readError)
            }
        } else {
            ProgressView()
        }
    }
}

struct SeatRow: View {
    var seat: RelaySeat

    var body: some View {
        // A Label keeps the dot centred on the name's first line at every text size.
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(seat.name)
                Text(seat.statusWords).font(.subheadline).foregroundStyle(SeatDot.colour(seat.look))
            }
        } icon: {
            SeatDot(look: seat.look)
        }
        .labelStyle(DotLabelStyle())
        .accessibilityElement(children: .combine)
    }
}

/// The dot beside the first line of text, at about half its x-height, at every text size. A plain Label in a List
/// takes the wide icon column instead.
struct DotLabelStyle: LabelStyle {
    @ScaledMetric(relativeTo: .body) private var lift = 4.5

    func makeBody(configuration: Configuration) -> some View {
        // A copy: the guide's closure is Sendable and can't capture the property wrapper.
        let lift = self.lift
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + lift }
            configuration.title
        }
    }
}

/// The seat's colour. The words beside it carry the state; the dot only repeats it.
struct SeatDot: View {
    var look: RelaySeat.Look
    @ScaledMetric(relativeTo: .body) private var size = 9.0

    var body: some View {
        Image(systemName: look == .down ? "circle" : "circle.fill")
            .font(.system(size: size))
            .foregroundStyle(Self.colour(look))
            .accessibilityHidden(true)
    }

    /// Also the status words' colour, as on the board.
    static func colour(_ look: RelaySeat.Look) -> Color {
        switch look {
        case .working: .statusGood
        case .needsYou: .statusBad
        case .idle, .down, .unknown: .secondary
        }
    }
}

/// What a seat is doing, from what the Mac knows, and Message and Queue a task under its name (board 6, seat
/// screens). No live terminal.
struct SeatScreen: View {
    @Environment(RemoteSession.self) private var model
    @Environment(RigsStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    var rig: String
    var session: String
    @State private var sheet: SeatSheet?

    var body: some View {
        Group {
            if let seat = store.seat(session) {
                content(seat)
            } else if let readError = store.readError {
                ContentUnavailableView {
                    Label("Can't show this seat", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(readError)
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(store.seat(session)?.name ?? "")
        .navigationBarTitleDisplayMode(.large)
        .refreshable { await store.loadSeats(rig: rig, macName: model.macName) }
        .task {
            #if DEBUG
                if sheet == nil { sheet = SeatSheet.launch }
            #endif
            while !Task.isCancelled {
                await store.loadSeats(rig: rig, macName: model.macName)
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .message: MessageComposer(session: session)
            case .task: TaskForm(session: session)
            }
        }
    }

    func content(_ seat: RelaySeat) -> some View {
        List {
            // Bare rows under the title, as on the board: no card, no separators.
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    // Monospaced only at standard sizes: at accessibility sizes it wraps to several lines.
                    Text(seat.session)
                        .font(typeSize.isAccessibilitySize ? .footnote : .footnote.monospaced())
                        .foregroundStyle(.secondary)
                    Label {
                        Text(seat.statusWords).foregroundStyle(SeatDot.colour(seat.look))
                    } icon: {
                        SeatDot(look: seat.look)
                    }
                    .labelStyle(DotLabelStyle())
                    .accessibilityElement(children: .combine)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            }

            // At accessibility sizes the two actions come first, so they show before anything scrolls (board 6).
            if typeSize.isAccessibilitySize { actionsSection(seat) }

            if let result = store.results[session] { Section { ResultRow(result: result) } }

            if seat.atPrompt { Section { PromptCard(command: store.prompts[session]) } }

            if !typeSize.isAccessibilitySize { actionsSection(seat) }

            Section("Working on") {
                if let row = seat.currentRow {
                    Text(row)
                } else {
                    Text("No active work.").foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent("Queue", value: seat.queueWords)
                LabeledContent("Context used", value: seat.contextWords ?? "not reported")
                LabeledContent("Runtime", value: seat.runtime ?? "not reported")
            } header: {
                Text("Seat")
            } footer: {
                Text("No terminal here. Watch or type on the Mac.")
            }
        }
        .listSectionSpacing(.compact)
    }

    func actionsSection(_ seat: RelaySeat) -> some View {
        Section {
            actions(seat)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        } footer: {
            if let words = seat.messageBlockedWords { Text(words) }
        }
    }

    /// Side by side as on the board; stacked at accessibility sizes so neither label is cut.
    func actions(_ seat: RelaySeat) -> some View {
        let layout =
            typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            Button {
                sheet = .message
            } label: {
                Text("Message").frame(maxWidth: .infinity)
            }
            .disabled(seat.messageBlocked != nil)
            Button {
                sheet = .task
            } label: {
                Text("Queue a task").frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .buttonBorderShape(.capsule)
    }
}

enum SeatSheet: String, Identifiable {
    case message, task
    var id: String { rawValue }
}

/// The seat is stopped at a prompt: what it asks to run. Answering is on the Needs-you list (task 11).
struct PromptCard: View {
    var command: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Stopped at a prompt · asks to run").font(.subheadline.weight(.semibold))
            if let command {
                Text(command).font(.footnote.monospaced()).lineLimit(3)
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.statusBad.opacity(0.12))
        .accessibilityElement(children: .combine)
    }
}

/// What the last message or task did. Plain words, with whether it went out.
struct ResultRow: View {
    var result: RigsStore.SendResult

    var body: some View {
        Label {
            Text(result.words)
        } icon: {
            Image(systemName: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(result.ok ? Color.statusGood : Color.statusBad)
        }
        .font(.subheadline)
    }
}

#if DEBUG
    extension DebugHooks {
        /// Opens this rig in the Rigs tab (with `OPENRIG_DEBUG_SCREEN=rigs`).
        static var openRig: String? { environment["OPENRIG_DEBUG_RIG"] }
        /// Opens this seat (a session) in the opened rig.
        static var openSeat: String? { environment["OPENRIG_DEBUG_SEAT"] }
        /// `message` or `task` opens that sheet on the opened seat.
        static var compose: String? { environment["OPENRIG_DEBUG_COMPOSE"] }
        /// The sheet's text: the message, or the task's summary. With `OPENRIG_DEBUG_SEND=1` it is sent.
        static var composeText: String? { environment["OPENRIG_DEBUG_TEXT"] }
    }

    extension RigsStore {
        /// A sheet opened at launch can come up before the seat list arrives.
        func debugWaitForSeat(_ session: String) async {
            for _ in 0..<50 where seat(session) == nil { try? await Task.sleep(for: .milliseconds(200)) }
        }
    }

    extension RigsLink {
        static var launchPath: [RigsLink] {
            guard let rig = DebugHooks.openRig else { return [] }
            guard let seat = DebugHooks.openSeat else { return [.rig(rig)] }
            return [.rig(rig), .seat(rig: rig, session: seat)]
        }
    }

    extension SeatSheet {
        static var launch: SeatSheet? { DebugHooks.compose.flatMap(SeatSheet.init(rawValue:)) }
    }
#endif
