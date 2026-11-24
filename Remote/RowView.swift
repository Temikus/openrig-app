import RigClient
import SwiftUI

/// An FYI, an ask without options, or a row held on the person, with the Mac's For You answers: Reply and Got it for
/// an FYI, Reply and Done for the rest. Reply sends a message to whoever sent the row and leaves it open.
struct RowView: View {
    @Environment(RemoteSession.self) private var model
    var id: String

    /// The row as last seen, so the screen stays once Got it or Done takes it off the list.
    @State private var lastSeen: RelayNeedsYouItem?
    @State private var replying = Self.launchReplying
    @State private var repliedAt: Date?
    @State private var closed: (action: NeedsYouList.RowAction, at: Date)?
    @State private var failure: String?
    /// The last call never left the phone, so it can be tried again.
    @State private var sending = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var item: RelayNeedsYouItem? { model.needsYouList?.rows.first { $0.row == id } ?? lastSeen }

    var body: some View {
        Group {
            if let item {
                content(item)
            } else {
                ContentUnavailableView(
                    "This is no longer waiting on you", systemImage: "checkmark.circle",
                    description: Text("It was answered on the Mac."))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.hidden, for: .tabBar)
        .onChange(of: model.needsYouList?.rows.first { $0.row == id }, initial: true) { _, live in
            if let live { lastSeen = live }
        }
        .sheet(isPresented: $replying) {
            if let item {
                ReplySheet(seat: item.sender, keepsOpen: item.kind == "fyi" ? "Got it" : "Done") { text in
                    replying = false
                    Task { await act(.reply, text: text) }
                }
            }
        }
    }

    func content(_ item: RelayNeedsYouItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(item.sender) · \(item.rig) · \(item.kindWords)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(item.title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                if let detail = item.detail { Text(detail).foregroundStyle(.secondary) }
                // At accessibility sizes notes scroll with the row, so the pinned bar holds only the buttons.
                if typeSize.isAccessibilitySize { notes(item).padding(.top, 12) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .safeAreaInset(edge: .bottom) {
            if !typeSize.isAccessibilitySize || closed == nil { bottom(item) }
        }
    }

    @ViewBuilder func bottom(_ item: RelayNeedsYouItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !typeSize.isAccessibilitySize { notes(item) }
            if closed == nil {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { buttons(item) }
                    VStack(spacing: 12) { buttons(item) }
                }
                .controlSize(.large)
                .disabled(sending || model.desk == nil)
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    @ViewBuilder func notes(_ item: RelayNeedsYouItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let closed {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(
                            "\(closed.action == .gotIt ? "Marked as seen" : "Marked done") · \(closed.at.formatted(date: .omitted, time: .shortened))"
                        )
                        .font(.headline)
                        Text("It has left Needs you.").font(.subheadline).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "checkmark").foregroundStyle(Color.statusGood)
                }
                .accessibilityElement(children: .combine)
            } else {
                if let repliedAt {
                    Label(
                        "Sent to \(item.sender) · \(repliedAt.formatted(date: .omitted, time: .shortened))",
                        systemImage: "checkmark"
                    )
                    .font(.footnote)
                }
                if let failure { Text(failure).font(.footnote) }
            }
        }
    }

    @ViewBuilder func buttons(_ item: RelayNeedsYouItem) -> some View {
        ForEach(NeedsYouList.actions(for: item), id: \.self) { action in
            switch action {
            case .reply:
                Button {
                    replying = true
                } label: {
                    Text("Reply…").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            case .gotIt, .done:
                Button {
                    Task { await act(action) }
                } label: {
                    Text(action == .gotIt ? "Got it" : "Done").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    func act(_ action: NeedsYouList.RowAction, text: String = "") async {
        guard let desk = model.desk, !sending else { return }
        sending = true
        failure = nil
        do throws(RelayDeskError) {
            switch action {
            case .reply: try await desk.reply(row: id, text: text)
            case .gotIt: try await desk.gotIt(row: id)
            case .done: try await desk.done(row: id, replied: repliedAt != nil)
            }
            if action == .reply { repliedAt = .now } else { closed = (action, .now) }
        } catch {
            failure = Self.words(error, mac: model.macName)
        }
        sending = false
        if closed != nil { await model.refresh() }
    }

    /// Each says whether anything was sent.
    static func words(_ error: RelayDeskError, mac: String) -> String {
        switch error {
        case .unreachable, .cancelled: "Couldn't reach \(mac). Nothing was sent."
        case .notForYou: "This is no longer waiting on you. Nothing was sent."
        case .lostReply: "\(mac) didn't reply, so it may have been done. Look on the Mac before trying again."
        case .actorMismatch(let message), .notFound(let message), .failed(let message), .decoding(let message):
            message
        default: "\(mac) refused it. Nothing was done."
        }
    }

    static var launchReplying: Bool {
        #if DEBUG
            DebugHooks.rowAction == "reply"
        #else
            false
        #endif
    }
}

/// Reply… on a row: a message to whoever sent it.
struct ReplySheet: View {
    var seat: String
    /// The button that closes the row afterwards.
    var keepsOpen: String
    var send: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @Environment(\.dynamicTypeSize) private var typeSize

    var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Your reply", text: $text, axis: .vertical).lineLimit(3...8)
                } footer: {
                    Text("\(seat) gets this as a message. The row stays here until you tap \(keepsOpen).")
                }
            }
            .navigationTitle("Reply to \(seat)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { send(trimmed) }.disabled(trimmed.isEmpty)
                }
            }
        }
        // Full height at accessibility sizes, so the pinned button never covers the field.
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.medium, .large])
    }
}
