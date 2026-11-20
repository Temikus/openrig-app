import RigCanvasLayout
import RigDomain
import RigModel
import SwiftUI

/// Seat state as the UI names it. Colour is always paired with a word.
enum SeatPhase: Equatable {
    case working, needsYou, idle, unknown
    /// Launching; the harness isn't ready yet.
    case starting
    /// Not up yet while its rig is starting.
    case waiting
    /// Its rig was stopped on purpose (`rig down`): not a crash, so no ✕.
    case stopped
    /// The session is gone: crashed, exited, or never started.
    case down(SeatPresence)

    /// `rigStarting`: a `rig up` for this rig is in flight, so a seat still down is waiting its turn. `rigStopped`: the
    /// whole rig is stopped, so an exited seat was stopped with it. A failed launch still shows as failed.
    init(_ seat: Seat, rigStarting: Bool = false, rigStopped: Bool = false) {
        let p = presence(seat)
        if p == .starting {
            self = .starting
        } else if p != .live {
            if rigStarting && p != .failed {
                self = .waiting
            } else {
                self = rigStopped && p == .exited ? .stopped : .down(p)
            }
        } else if seat.needsAttention || seat.activity?.state == .needsInput {
            self = .needsYou
        } else {
            switch seat.activity?.state {
            case .running?: self = .working
            case .idle?: self = .idle
            default: self = .unknown
            }
        }
    }

    var label: String {
        switch self {
        case .working: "working"
        case .needsYou: "needs you"
        case .idle: "idle"
        case .unknown: "no status"
        case .starting: "starting…"
        case .waiting: "waiting to start"
        case .stopped: "stopped"
        case .down(.lost): "session lost"
        case .down(.failed): "failed to start"
        case .down: "exited"
        }
    }

    /// Orange, not red: red means a question is waiting, and nothing here is asking.
    var color: Color {
        switch self {
        case .working, .starting: .green
        case .needsYou: .attention
        case .down(let p) where p.needsYou: .orange
        default: .secondary
        }
    }

    /// Not running: dashed border, stalled work. Includes a stopped rig's seats.
    var isDown: Bool {
        if case .down = self { true } else { self == .stopped }
    }
}

struct StatusDot: View {
    let phase: SeatPhase

    var body: some View {
        Group {
            if phase == .stopped {
                Circle().strokeBorder(phase.color, lineWidth: 1.5)
            } else if phase.isDown {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(phase.color)
            } else if phase == .unknown || phase == .starting || phase == .waiting {
                Circle().strokeBorder(phase.color, lineWidth: 1.5)
            } else {
                Circle().fill(phase.color)
            }
        }
        .frame(width: 8, height: 8)
        .accessibilityHidden(true)
    }
}

/// Compact age: "now", "4m", "3h", "2d".
func compactAge(since date: Date?, now: Date) -> String? {
    guard let date else { return nil }
    let seconds = max(0, now.timeIntervalSince(date))
    switch seconds {
    case ..<60: return "now"
    case ..<3600: return "\(Int(seconds / 60))m"
    case ..<86_400: return "\(Int(seconds / 3600))h"
    default: return "\(Int(seconds / 86_400))d"
    }
}

struct SeatNode: View {
    let seat: Seat
    let isSelected: Bool
    let selectedQItem: QItem.ID?
    let showsModel: Bool
    var prompt: PromptInstance?
    var linked: QItem?
    var rigStarting = false
    var rigStopped = false
    var select: () -> Void = {}
    @Environment(\.appearsActive) private var appearsActive

    private var phase: SeatPhase {
        prompt == nil ? SeatPhase(seat, rigStarting: rigStarting, rigStopped: rigStopped) : .needsYou
    }

    private var borderColor: Color {
        switch phase {
        case .needsYou: .attention
        case .starting: .green.opacity(0.6)
        case _ where phase.isDown: phase.color
        default: Color(nsColor: .separatorColor)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: select) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    Divider()
                    workLine
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // On the button, not the node: a label on the node is inherited by the prompt's buttons inside it.
            .accessibilityLabel("\(seat.displayName), \(phase.label)")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            if let prompt {
                Divider()
                // Inline permission card, so the prompt can be answered from the canvas.
                PermissionControl(prompt: prompt, linked: linked, compact: true)
                    .padding(10)
            }
        }
        .frame(width: LayoutMetrics().seatWidth, alignment: .leading)
        .background(.background, in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    borderColor,
                    style: StrokeStyle(lineWidth: 1, dash: phase.isDown || phase == .waiting ? [5, 3] : []))
        }
        .overlay {
            if isSelected {
                // The same ring as a selected queue card: accent, grey when the window is inactive.
                RoundedRectangle(cornerRadius: 13)
                    .strokeBorder(appearsActive ? Color.accentColor : .secondary, lineWidth: 2)
                    .padding(-3)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(seat.displayName)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Fixed height so the wire ports (22 pt down) meet the name line.
            HStack(spacing: 7) {
                StatusDot(phase: phase)
                Text(seat.displayName)
                    .font(.system(.body, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if showsModel, let model = seat.model {
                    Text(shortModelName(model))
                        .font(.caption2.monospaced())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: .rect(cornerRadius: 4))
                }
            }
            .frame(height: 20)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(stateLine(now: context.date))
                    .font(.caption)
                    .foregroundStyle(phase == .idle || phase == .unknown ? .secondary : phase.color)
                    .lineLimit(1)
                    .padding(.leading, 15)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private func stateLine(now: Date) -> String {
        var parts = [phase.label]
        if let prompt {
            parts.append("permission")
            if let age = compactAge(since: prompt.observedAt, now: now) { parts.append(age) }
            return parts.joined(separator: " · ")
        }
        if phase == .needsYou, let reason = seat.activity?.reason {
            parts.append(reason.replacingOccurrences(of: "_", with: " "))
        }
        if let age = compactAge(since: seat.activity?.since, now: now) { parts.append(age) }
        // The word is the only sign: the card is no longer dimmed (the dot grid showed through it).
        if seat.activity?.stale == true && phase != .needsYou { parts.append("stale") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var workLine: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let item = seat.currentQItems.first {
                Text("\(shortQItemID(item.id)) · \(phase.isDown ? "stalled" : "in progress")")
                    .font(.caption.monospaced())
                    .foregroundStyle(item.id == selectedQItem ? Color.primary : .secondary)
                    .padding(.horizontal, item.id == selectedQItem ? 4 : 0)
                    .overlay {
                        if item.id == selectedQItem {
                            RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary, lineWidth: 1.5)
                        }
                    }
                    .help(item.id)
                Text(item.bodyExcerpt.isEmpty ? "No summary" : item.bodyExcerpt)
                    .font(.callout)
                    .lineLimit(2)
            } else if seat.work.pending + seat.work.blocked > 0 {
                Text(workCounts)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("no work")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var workCounts: String {
        [
            seat.work.pending > 0 ? "\(seat.work.pending) pending" : nil,
            seat.work.blocked > 0 ? "\(seat.work.blocked) blocked" : nil,
        ].compactMap(\.self).joined(separator: " · ")
    }
}

/// "claude-opus-5-5" → "opus 5.5".
func shortModelName(_ model: String) -> String {
    var parts = model.split(separator: "-").map(String.init)
    if parts.first == "claude" { parts.removeFirst() }
    guard let family = parts.first else { return model }
    let version = parts.dropFirst().joined(separator: ".")
    return version.isEmpty ? family : "\(family) \(version)"
}
