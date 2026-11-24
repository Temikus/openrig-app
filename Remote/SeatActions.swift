import RigClient
import SwiftUI

/// Types a message into a seat, as `rig send` does. Off while the seat is stopped at a prompt; the draft stays.
struct MessageComposer: View {
    @Environment(RigsStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var session: String
    @State private var sending = false
    @FocusState private var focused: Bool

    var body: some View {
        let seat = store.seat(session)
        let name = seat?.name ?? "this seat"
        NavigationStack {
            Form {
                // The seat refreshes underneath: if it stops at a prompt while the person types, say so here.
                if let words = seat?.composerBlockedWords {
                    Section {
                        Label {
                            Text(words)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.statusBad)
                        }
                    }
                }
                if let result = store.results[session], !result.ok { Section { ResultRow(result: result) } }
                Section {
                    TextField("Message", text: draft, axis: .vertical)
                        .lineLimit(5...)
                        .focused($focused)
                } footer: {
                    Text("Arrives in \(name)'s terminal as you.")
                }
            }
            .navigationTitle("Message \(name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { Task { await send() } }
                        .disabled(!canSend(seat))
                }
            }
            .disabled(sending)
            .onAppear { focused = true }
            #if DEBUG
                .task {
                    if let text = DebugHooks.composeText, draft.wrappedValue.isEmpty { draft.wrappedValue = text }
                    await store.debugWaitForSeat(session)
                    if DebugHooks.send, canSend(store.seat(session)) { await send() }
                }
            #endif
        }
    }

    var draft: Binding<String> {
        Binding(get: { store.messageDrafts[session] ?? "" }, set: { store.messageDrafts[session] = $0 })
    }

    func canSend(_ seat: RelaySeat?) -> Bool {
        guard let seat, seat.messageBlocked == nil, !sending else { return false }
        return !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func send() async {
        guard let seat = store.seat(session) else { return }
        sending = true
        await store.message(draft.wrappedValue, to: seat)
        sending = false
        if store.results[session]?.ok == true { dismiss() }
    }
}

/// Queues a task for a seat: a summary and a body. Stays on at a prompt, since the task waits in the queue.
struct TaskForm: View {
    @Environment(RigsStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var session: String
    @State private var sending = false
    @FocusState private var focused: Bool

    var body: some View {
        let seat = store.seat(session)
        let name = seat?.name ?? "this seat"
        NavigationStack {
            Form {
                if let result = store.results[session], !result.ok { Section { ResultRow(result: result) } }
                Section {
                    TextField("Summary", text: summary, axis: .vertical).focused($focused)
                }
                Section {
                    TextField("What to do, and what counts as done", text: details, axis: .vertical)
                        .lineLimit(6...)
                } footer: {
                    Text("Goes to \(name)'s queue from you. It waits there until the seat takes it.")
                }
            }
            .navigationTitle("Task for \(name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Queue") { Task { await send() } }.disabled(!canSend(seat))
                }
            }
            .disabled(sending)
            .onAppear { focused = true }
            #if DEBUG
                .task {
                    if let text = DebugHooks.composeText, summary.wrappedValue.isEmpty { summary.wrappedValue = text }
                    await store.debugWaitForSeat(session)
                    if DebugHooks.send, canSend(store.seat(session)) { await send() }
                }
            #endif
        }
    }

    var summary: Binding<String> {
        Binding(
            get: { store.taskDrafts[session]?.summary ?? "" },
            set: { store.taskDrafts[session] = ($0, store.taskDrafts[session]?.body ?? "") })
    }

    var details: Binding<String> {
        Binding(
            get: { store.taskDrafts[session]?.body ?? "" },
            set: { store.taskDrafts[session] = (store.taskDrafts[session]?.summary ?? "", $0) })
    }

    func canSend(_ seat: RelaySeat?) -> Bool {
        guard seat != nil, !sending else { return false }
        return !summary.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func send() async {
        guard let seat = store.seat(session) else { return }
        sending = true
        await store.task(summary: summary.wrappedValue, body: details.wrappedValue, for: seat)
        sending = false
        if store.results[session]?.ok == true { dismiss() }
    }
}
