import RigClient
import RigDomain
import RigModel
import SwiftUI

/// The toolbar's Stop Rig button and its confirmation popover, which names the seats a stop would cut off mid-turn.
struct RigStopButton: View {
    let summary: RigSummary
    @Environment(AppStore.self) private var store
    @State private var confirming = false

    var body: some View {
        Button("Stop Rig", systemImage: "power") { confirming = true }
            .labelStyle(.iconOnly)
            .help(store.rigOps[summary.id] == .stopping ? "Stopping \(summary.name)…" : "Stop \(summary.name)…")
            .disabled(store.rigOps[summary.id] != nil || !store.isUp)
            .onChange(of: store.stopRequests) { confirming = true }
            .popover(isPresented: $confirming, arrowEdge: .bottom) {
                StopRigConfirmation(summary: summary, graph: store.rig?.graph) { confirming = false }
                    .environment(store)
            }
    }
}

struct StopRigConfirmation: View {
    let summary: RigSummary
    let graph: RigGraph?
    let done: () -> Void
    @Environment(AppStore.self) private var store

    private var risk: StopRisk { graph.map(stopRisk) ?? StopRisk(working: [], idle: summary.runningCount) }
    private var action: RigAction { .rigDown(rig: summary.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Stop \(summary.name)?").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(risk.working) { seat in
                    HStack(spacing: 6) {
                        StatusDot(phase: .working)
                        Text(seat.displayName)
                        Text(workText(seat)).foregroundStyle(.secondary)
                    }
                }
                if risk.working.isEmpty {
                    Text("No seat is mid-turn.").foregroundStyle(.secondary)
                } else {
                    Text("A seat mid-turn stops mid-task.").foregroundStyle(.secondary)
                }
                if risk.idle > 0 {
                    Text("\(risk.idle) \(risk.idle == 1 ? "seat" : "seats") idle.").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            Text("OpenRig takes a snapshot first, so Start Rig resumes each seat's conversation.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text(action.displayCommand)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                // Not the default button: Return shouldn't stop a team.
                Button(stopTitle, role: .destructive) {
                    done()
                    Task { await store.stopRig(summary) }
                }
                .help(action.displayCommand)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private var stopTitle: String {
        let n = risk.live
        return n > 0 ? "Stop \(n) \(n == 1 ? "Seat" : "Seats")" : "Stop Rig"
    }

    private func workText(_ seat: Seat) -> String {
        seat.currentQItems.first.map { "working on \(shortQItemID($0.id))" } ?? "working"
    }
}

/// Above a stopped rig's view: says it's stopped and read-only, with Start Rig. Louder than the daemon banner so a
/// stopped rig can't pass for a quiet one.
struct StoppedRigBanner: View {
    let summary: RigSummary
    @Environment(AppStore.self) private var store

    var body: some View {
        let action = RigAction.rigUp(rig: summary.name)
        HStack(spacing: 12) {
            Image(systemName: "power")
                .font(.title2)
                .foregroundStyle(summary.lifecycle == .recoverable ? Color.orange : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    summary.lifecycle == .recoverable
                        ? "\(summary.name) stopped unexpectedly" : "\(summary.name) is stopped"
                )
                .font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            ActionStatusLine(key: AppStore.rigKey(summary.id))
            Button("Start Rig") { Task { await store.startRig(summary) } }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(store.rigOps[summary.id] != nil || !store.isUp)
                .help(action.displayCommand)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }

    private var detail: String {
        var parts = ["\(summary.nodeCount) \(summary.nodeCount == 1 ? "seat" : "seats")", "read-only"]
        if let snapshot = summary.latestSnapshot { parts.insert("last snapshot \(snapshot)", at: 1) }
        return parts.joined(separator: " · ")
    }
}
