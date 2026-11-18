import RigCanvasLayout
import RigModel
import SwiftUI

/// Seat state as the UI names it. Colour is always paired with a word.
enum SeatPhase {
    case working, needsYou, idle, unknown

    init(_ seat: Seat) {
        if seat.needsAttention || seat.activity?.state == .needsInput {
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
        case .unknown: "unknown"
        }
    }

    var color: Color {
        switch self {
        case .working: .green
        case .needsYou: .red
        case .idle, .unknown: .secondary
        }
    }
}

struct StatusDot: View {
    let phase: SeatPhase

    var body: some View {
        Group {
            if phase == .unknown {
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

    private var phase: SeatPhase { SeatPhase(seat) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            workLine
        }
        .frame(width: LayoutMetrics().seatWidth, alignment: .leading)
        .background(.background, in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(phase == .needsYou ? Color.red : Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 13).strokeBorder(Color.primary, lineWidth: 2).padding(-3)
            }
        }
        .opacity(seat.activity?.stale == true && phase != .needsYou ? 0.85 : 1)
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
                    .foregroundStyle(phase == .needsYou ? Color.red : phase == .working ? .green : .secondary)
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
        if phase == .needsYou, let reason = seat.activity?.reason {
            parts.append(reason.replacingOccurrences(of: "_", with: " "))
        }
        if let age = compactAge(since: seat.activity?.since, now: now) { parts.append(age) }
        if seat.activity?.stale == true && phase == .unknown { parts.append("stale") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var workLine: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let item = seat.currentQItems.first {
                Text("\(shortQItemID(item.id)) · in progress")
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
