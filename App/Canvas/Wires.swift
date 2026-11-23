import AppKit
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
        // Quiet at rest: watch lines are context, not flow. `focused` restores them for a hovered or selected seat.
        case .observes: WireStyle(color: .secondary.opacity(0.45), width: 1, dash: [7, 5])
        case .related: WireStyle(color: .secondary.opacity(0.5), width: 1.5, dash: [2, 4])
        case .inFlight: WireStyle(color: .moving, width: 3, dash: [])
        case .needsYou: WireStyle(color: .attention, width: 3, dash: [])
        case .next: WireStyle(color: .moving, width: 2, dash: [6, 4])
        case .past: WireStyle(color: .secondary.opacity(0.6), width: 1.5, dash: [1.5, 4])
        }
    }

    /// Full strength, for a wire whose seat is hovered or selected.
    static func focused(_ kind: WireKind) -> WireStyle {
        kind == .observes ? WireStyle(color: .secondary.opacity(0.75), width: 1.5, dash: [7, 5]) : of(kind)
    }

    /// With Differentiate Without Color, needs-you wires get a dash-dot no other kind uses: otherwise they differ
    /// from in-flight ones by hue alone.
    func differentiated(_ kind: WireKind, _ on: Bool) -> WireStyle {
        guard on || Self.debugDifferentiate, kind == .needsYou else { return self }
        var style = self
        style.dash = [12, 4, 2, 4]
        return style
    }

    #if DEBUG
        /// OPENRIG_DEBUG_DIFFERENTIATE=1 acts as if Differentiate Without Color were on.
        static let debugDifferentiate = ProcessInfo.processInfo.environment["OPENRIG_DEBUG_DIFFERENTIATE"] == "1"
    #else
        static let debugDifferentiate = false
    #endif

    var strokeStyle: StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: dash)
    }
}

struct WireLayer: View {
    let routes: RouteResult
    let selectedQItem: QItem.ID?
    /// Hovered and selected seats: their wires draw at full strength.
    var focus: Set<String> = []
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let sharp = Set(routes.junctions)
        let shining = reduceMotion ? [] : routes.wires.filter { $0.kind == .inFlight }
        ZStack {
            Canvas { context, _ in
                // Spec edges first so work wires (M2) draw on top.
                let order: [WireKind] = [.related, .observes, .delegates, .past, .next, .inFlight, .needsYou]
                for kind in order {
                    for wire in routes.wires where wire.kind == kind {
                        let style = style(wire)
                        let path = Path(roundedPath(wire.points, sharp: sharp))
                        if let selectedQItem, wire.id == "q:\(selectedQItem)" {
                            // Selection ring: a wider halo under the wire.
                            context.stroke(
                                path, with: .color(.primary.opacity(0.25)),
                                style: StrokeStyle(lineWidth: style.width + 6, lineCap: .round, lineJoin: .round))
                        }
                        // Under the sheen the wire steps back so the band stands out; not with Increase Contrast.
                        let dims = !shining.isEmpty && wire.kind == .inFlight && contrast != .increased
                        context.stroke(
                            path, with: .color(dims ? style.color.opacity(0.6) : style.color),
                            style: style.strokeStyle)
                        if let start = wire.points.first, let end = wire.points.last {
                            for p in [start, end] {
                                context.fill(
                                    Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)),
                                    with: .color(style.color))
                            }
                        }
                    }
                }
                // Smaller than the port dots, in the colour of the wire that branches there.
                for j in routes.junctions {
                    let color = branching(at: j).map { style($0).color } ?? .secondary
                    context.fill(
                        Path(ellipseIn: CGRect(x: j.x - 2.25, y: j.y - 2.25, width: 4.5, height: 4.5)),
                        with: .color(color))
                }
            }
            if !shining.isEmpty {
                // White would vanish on a light canvas, so there the band is the wire's own green at full strength.
                SheenBands(
                    wires: shining, sharp: sharp,
                    color: colorScheme == .dark ? Color.moving.mix(with: .white, by: 0.85) : Color.moving)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func style(_ wire: Wire) -> WireStyle {
        let style: WireStyle =
            contrast == .increased || focus.contains(wire.source) || focus.contains(wire.target)
            ? .focused(wire.kind) : .of(wire.kind)
        return style.differentiated(wire.kind, differentiate)
    }

    /// The most prominent wire through a junction (drawn last of those on it).
    private func branching(at p: CGPoint) -> Wire? {
        let order: [WireKind] = [.related, .observes, .delegates, .past, .next, .inFlight, .needsYou]
        return routes.wires.filter { w in
            w.segments.contains { a, b in
                (a.x == b.x && p.x == a.x && min(a.y, b.y) <= p.y && p.y <= max(a.y, b.y))
                    || (a.y == b.y && p.y == a.y && min(a.x, b.x) <= p.x && p.x <= max(a.x, b.x))
            }
        }.max { (order.firstIndex(of: $0.kind) ?? 0) < (order.firstIndex(of: $1.kind) ?? 0) }
    }
}

/// The sheen on in-flight wires (`Wire.points` run out port to in port, so the band moves sender to receiver).
/// Core Animation runs it; the layers are rebuilt only when the wires or the colour change.
struct SheenBands: NSViewRepresentable {
    let wires: [Wire]
    let sharp: Set<CGPoint>
    let color: Color

    func makeNSView(context: Context) -> BandsView { BandsView() }

    func updateNSView(_ view: BandsView, context: Context) {
        view.show(wires: wires, sharp: sharp, color: color.resolve(in: context.environment).cgColor)
    }

    final class BandsView: NSView {
        private let sheen = Sheen()
        private var shown: (wires: [Wire], sharp: Set<CGPoint>, color: CGColor)?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            setAccessibilityElement(false)
        }

        required init?(coder: NSCoder) { nil }

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            layer?.sublayers?.forEach { $0.contentsScale = bandScale }
        }

        /// Sharp up to the canvas's 200% zoom, which scales this view rather than redrawing it.
        private var bandScale: CGFloat { (window?.backingScaleFactor ?? 2) * 2 }

        func show(wires: [Wire], sharp: Set<CGPoint>, color: CGColor) {
            if let shown, shown.wires == wires, shown.sharp == sharp, shown.color == color { return }
            shown = (wires, sharp, color)
            guard let root = layer else { return }
            root.sublayers?.forEach { $0.removeFromSuperlayer() }
            let now = CACurrentMediaTime()
            for wire in wires {
                let path = roundedPath(wire.points, sharp: sharp)
                let length = Sheen.length(wire.points)
                let duration = sheen.duration(length: length)
                // From the media clock, so a rebuild (every poll that changes a wire) doesn't restart the bands.
                let offset = (now + sheen.timeOffset(length: length, id: wire.id))
                    .truncatingRemainder(dividingBy: duration)
                for (i, spec) in sheen.layers.enumerated() {
                    let band = CAShapeLayer()
                    band.path = path
                    band.fillColor = nil
                    band.strokeColor = color.copy(alpha: color.alpha * spec.opacity)
                    band.lineWidth = spec.width
                    band.lineCap = .round
                    band.lineJoin = .round
                    band.strokeStart = 0
                    band.strokeEnd = 0
                    band.contentsScale = bandScale
                    let frames = sheen.keyframes(length: length, layer: i)
                    for (key, keyframes) in [("strokeStart", frames.start), ("strokeEnd", frames.end)] {
                        let animation = CAKeyframeAnimation(keyPath: key)
                        animation.values = keyframes.map(\.value)
                        animation.keyTimes = keyframes.map { NSNumber(value: Double($0.time)) }
                        animation.calculationMode = .linear
                        animation.duration = duration
                        animation.repeatCount = .infinity
                        animation.timeOffset = offset
                        band.add(animation, forKey: key)
                    }
                    root.addSublayer(band)
                }
            }
        }
    }
}

/// Floating legend and zoom controls.
struct LegendBar: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate
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

    /// A 24-point target around a caption-sized glyph.
    private func zoomButton(
        _ title: String, systemImage: String, help: String, _ action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .help(help)
    }

    private func bar(showsLegend: Bool) -> some View {
        HStack(spacing: 14) {
            if showsLegend {
                ForEach(entries, id: \.0) { kind, label in
                    HStack(spacing: 5) {
                        // Full strength: a resting "observes" swatch would vanish on the glass bar.
                        LegendSwatch(style: WireStyle.focused(kind).differentiated(kind, differentiate))
                        Text(label)
                    }
                }
                Divider().frame(height: 16)
            }
            HStack(spacing: 8) {
                // The shortcuts live on View › Zoom In, Zoom Out and Zoom to Fit.
                zoomButton("Zoom out", systemImage: "minus", help: "Zoom out (⌘-)") { zoom = clampZoom(zoom - 0.1) }
                Text("\(Int((zoom * 100).rounded()))%").monospacedDigit().frame(minWidth: 38)
                zoomButton("Zoom in", systemImage: "plus", help: "Zoom in (⌘=)") { zoom = clampZoom(zoom + 0.1) }
                zoomButton("Fit", systemImage: "arrow.up.left.and.arrow.down.right", help: "Zoom to fit (⌘0)", fit)
            }
            .buttonStyle(.borderless)
        }
        .fixedSize()
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .modifier(FloatingSurface(solid: reduceTransparency))
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
                let color = phase.color
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
    /// Replaces the default "q-0412" text, e.g. "next: review".
    var label: String?
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            Text(label ?? (kind == .needsYou ? "\(shortQItemID(item.id)) · blocked" : shortQItemID(item.id)))
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
        .accessibilityLabel("\(label ?? shortQItemID(item.id)), \(item.summary)")
    }
}

/// Glass for floating controls, or an opaque surface when Reduce Transparency is on.
struct FloatingSurface: ViewModifier {
    let solid: Bool

    func body(content: Content) -> some View {
        if solid {
            content
                .background(Color(nsColor: .windowBackgroundColor), in: .capsule)
                .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor)))
        } else {
            content.glassEffect()
        }
    }
}
