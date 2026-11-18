import RigCanvasLayout
import RigDomain
import RigModel
import SwiftUI

/// How each wire kind is drawn. Shared by the canvas and the legend so they can't drift apart.
struct WireStyle {
    var color: Color
    var width: CGFloat
    var dash: [CGFloat]

    static func of(_ kind: WireKind) -> WireStyle {
        switch kind {
        case .delegates: WireStyle(color: .secondary.opacity(0.7), width: 1.5, dash: [])
        case .observes: WireStyle(color: .secondary.opacity(0.7), width: 1.5, dash: [7, 5])
        case .related: WireStyle(color: .secondary.opacity(0.5), width: 1.5, dash: [2, 4])
        case .inFlight: WireStyle(color: .orange, width: 3, dash: [])
        case .needsYou: WireStyle(color: .red, width: 3, dash: [])
        case .next: WireStyle(color: .orange, width: 2, dash: [6, 4])
        case .past: WireStyle(color: .secondary.opacity(0.6), width: 1.5, dash: [1.5, 4])
        }
    }

    var strokeStyle: StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: dash)
    }
}

struct WireLayer: View {
    let routes: RouteResult
    let selectedQItem: QItem.ID?

    var body: some View {
        Canvas { context, _ in
            // Spec edges first so work wires (M2) draw on top.
            let order: [WireKind] = [.related, .observes, .delegates, .past, .next, .inFlight, .needsYou]
            for kind in order {
                let style = WireStyle.of(kind)
                for wire in routes.wires where wire.kind == kind {
                    let path = Path(roundedPath(wire.points))
                    if let selectedQItem, wire.id == "q:\(selectedQItem)" {
                        // Selection ring: a wider halo under the wire.
                        context.stroke(
                            path, with: .color(.primary.opacity(0.25)),
                            style: StrokeStyle(lineWidth: style.width + 6, lineCap: .round, lineJoin: .round))
                    }
                    context.stroke(path, with: .color(style.color), style: style.strokeStyle)
                    if let start = wire.points.first, let end = wire.points.last {
                        for p in [start, end] {
                            context.fill(
                                Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)),
                                with: .color(style.color))
                        }
                    }
                }
            }
            for j in routes.junctions {
                context.fill(
                    Path(ellipseIn: CGRect(x: j.x - 3, y: j.y - 3, width: 6, height: 6)), with: .color(.secondary))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Floating legend and zoom controls.
struct LegendBar: View {
    @Binding var zoom: CGFloat
    let fit: () -> Void

    private let entries: [(WireKind, String)] = [
        (.inFlight, "in flight"), (.needsYou, "needs you"), (.delegates, "spec edge"),
        (.next, "next hop"), (.past, "past hop"), (.observes, "observes"),
    ]

    var body: some View {
        // Drops the legend entries before it would wrap them.
        ViewThatFits(in: .horizontal) {
            bar(showsLegend: true)
            bar(showsLegend: false)
        }
    }

    private func bar(showsLegend: Bool) -> some View {
        HStack(spacing: 14) {
            if showsLegend {
                ForEach(entries, id: \.0) { kind, label in
                    HStack(spacing: 5) {
                        LegendSwatch(style: .of(kind))
                        Text(label)
                    }
                }
                Divider().frame(height: 16)
            }
            HStack(spacing: 8) {
                Button("Zoom out", systemImage: "minus") { zoom = clampZoom(zoom - 0.1) }
                    .keyboardShortcut("-")
                Text("\(Int((zoom * 100).rounded()))%").monospacedDigit().frame(minWidth: 38)
                Button("Zoom in", systemImage: "plus") { zoom = clampZoom(zoom + 0.1) }
                    .keyboardShortcut("=")
                Button("Fit", systemImage: "arrow.up.left.and.arrow.down.right") { fit() }
                    .keyboardShortcut("0")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
        .fixedSize()
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .glassEffect()
    }
}

struct LegendSwatch: View {
    let style: WireStyle

    var body: some View {
        Canvas { context, size in
            var p = Path()
            p.move(to: CGPoint(x: 0, y: size.height / 2))
            p.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(p, with: .color(style.color), style: style.strokeStyle)
        }
        .frame(width: 18, height: 6)
        .accessibilityHidden(true)
    }
}

/// Overview of the whole rig with the visible region outlined. Click to jump.
struct Minimap: View {
    let graph: RigGraph
    let layout: CanvasLayout
    let zoom: CGFloat
    let visible: CGRect
    let jump: (CGPoint) -> Void

    private let width: CGFloat = 150

    var body: some View {
        let scale = width / layout.bounds.width
        let height = layout.bounds.height * scale
        Canvas { context, _ in
            for frame in layout.pods.values {
                context.fill(
                    Path(roundedRect: frame.scaled(scale), cornerRadius: 3), with: .color(.secondary.opacity(0.2)))
            }
            for seat in graph.seats {
                guard let frame = layout.seats[seat.id] else { continue }
                let phase = SeatPhase(seat)
                let color: Color = phase == .needsYou ? .red : phase == .working ? .green : .secondary
                context.fill(Path(roundedRect: frame.scaled(scale), cornerRadius: 2), with: .color(color.opacity(0.7)))
            }
            let view = CGRect(
                x: visible.minX / zoom, y: visible.minY / zoom, width: visible.width / zoom,
                height: visible.height / zoom)
            context.stroke(Path(view.scaled(scale)), with: .color(.primary.opacity(0.6)), lineWidth: 1)
        }
        .frame(width: width, height: height)
        .padding(8)
        .background(.background.opacity(0.9), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
        .contentShape(Rectangle())
        .onTapGesture { location in
            jump(CGPoint(x: (location.x - 8) / scale, y: (location.y - 8) / scale))
        }
        .accessibilityLabel("Minimap")
    }
}

extension CGRect {
    func scaled(_ s: CGFloat) -> CGRect {
        CGRect(x: minX * s, y: minY * s, width: width * s, height: height * s)
    }
}

/// The label on a work wire, e.g. "q-0412" or "q-0409 · blocked". Click selects the qitem.
struct WireChip: View {
    let item: QItem
    let kind: WireKind
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            Text(kind == .needsYou ? "\(shortQItemID(item.id)) · blocked" : shortQItemID(item.id))
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(WireStyle.of(kind).color, in: .rect(cornerRadius: 4))
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary, lineWidth: 2).padding(-3)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(item.summary)
        .accessibilityLabel("\(shortQItemID(item.id)), \(item.summary)")
    }
}
