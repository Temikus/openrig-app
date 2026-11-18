import RigCanvasLayout
import RigDomain
import RigModel
import SwiftUI

/// The rig as a node graph: pods, seats, and spec edges routed metro-style.
struct CanvasView: View {
    @Environment(RigStore.self) private var rig
    @Environment(SelectionStore.self) private var selection
    @State private var zoom: CGFloat = 1
    @State private var pinchStart: CGFloat?
    @State private var scroll = ScrollPosition(edge: .top)
    @State private var visible: CGRect = .zero
    /// Until the user zooms by hand, the canvas keeps fitting the window.
    @State private var userZoomed = false

    var body: some View {
        if let graph = rig.graph, let layout = rig.layout {
            ScrollView([.horizontal, .vertical]) {
                CanvasContent(graph: graph, layout: layout, routes: rig.routes(selected: selection.qitemID))
                    .frame(width: layout.bounds.width, height: layout.bounds.height)
                    .scaleEffect(zoom, anchor: .topLeading)
                    .frame(
                        width: layout.bounds.width * zoom, height: layout.bounds.height * zoom,
                        alignment: .topLeading)
            }
            .scrollPosition($scroll)
            .onScrollGeometryChange(for: CGRect.self) { geo in
                // The canvas runs under the floating sidebar and inspector; only the inset part is visible.
                let i = geo.contentInsets
                return CGRect(
                    x: geo.visibleRect.minX + i.leading, y: geo.visibleRect.minY + i.top,
                    width: geo.visibleRect.width - i.leading - i.trailing,
                    height: geo.visibleRect.height - i.top - i.bottom)
            } action: { _, rect in
                // Ignore changes smaller than a scroll bar: fitting can show or hide the scrollers,
                // which resizes the viewport, which would refit again, forever.
                let resized =
                    abs(rect.width - visible.width) > 20 || abs(rect.height - visible.height) > 20
                visible = rect
                if resized, !userZoomed { fit(layout) }
            }
            .defaultScrollAnchor(.center)
            .onChange(of: layout.bounds.size) { if !userZoomed { fit(layout) } }
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        let start = pinchStart ?? zoom
                        pinchStart = start
                        zoom = clampZoom(start * value.magnification)
                        userZoomed = true
                    }
                    .onEnded { _ in pinchStart = nil }
            )
            // Overlays, not a ZStack: floating controls must not set the column's minimum width.
            .overlay(alignment: .bottom) {
                LegendBar(
                    zoom: Binding(
                        get: { zoom },
                        set: {
                            zoom = $0
                            userZoomed = true
                        }),
                    fit: {
                        userZoomed = false
                        fit(layout)
                    }
                )
                .padding(.bottom, 16)
            }
            .overlay(alignment: .bottomTrailing) {
                if visible.width >= 720 {
                    Minimap(graph: graph, layout: layout, zoom: zoom, visible: visible) { point in
                        scroll.scrollTo(
                            point: CGPoint(
                                x: max(0, point.x * zoom - visible.width / 2),
                                y: max(0, point.y * zoom - visible.height / 2)))
                    }
                    .padding(.trailing, 16)
                    .padding(.bottom, 64)
                }
            }
        } else if let error = rig.error {
            ContentUnavailableView(
                "Couldn't load rig", systemImage: "exclamationmark.triangle", description: Text(error))
        } else {
            ProgressView()
        }
    }

    private func fit(_ layout: CanvasLayout) {
        guard visible.width > 0, visible.height > 0 else { return }
        // The visible rect's size is the viewport's, whatever the zoom. Leave room for the legend.
        let scale = min(visible.width / layout.bounds.width, (visible.height - 60) / layout.bounds.height)
        // A 4% margin keeps fitted content clear of the scrollers' threshold.
        zoom = clampZoom(min(scale * 0.96, 1.25))
        scroll.scrollTo(edge: .top)
    }
}

func clampZoom(_ z: CGFloat) -> CGFloat { min(max(z, 0.4), 2) }

struct CanvasContent: View {
    let graph: RigGraph
    let layout: CanvasLayout
    let routes: RouteResult
    @Environment(RigStore.self) private var rig
    @Environment(SelectionStore.self) private var selection

    private var commonModel: String? {
        let counts = Dictionary(grouping: graph.seats.compactMap(\.model), by: { $0 }).mapValues(\.count)
        return counts.max { $0.value < $1.value }?.key
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            DotGrid()
            ForEach(podFrames, id: \.id) { pod in
                PodGroup(title: pod.title, seatCount: pod.count)
                    .frame(width: pod.frame.width, height: pod.frame.height)
                    .offset(x: pod.frame.minX, y: pod.frame.minY)
            }
            WireLayer(routes: routes, selectedQItem: selection.qitemID)
            ForEach(chips, id: \.wire.id) { chip in
                WireChip(
                    item: chip.item, kind: chip.wire.kind, label: chip.label,
                    isSelected: chip.wire.kind != .next && chip.item.id == selection.qitemID
                ) { selection.select(qitem: chip.item.id) }
                .position(chip.anchor)
            }
            ForEach(graph.seats) { seat in
                if let frame = layout.seats[seat.id] {
                    // Not wrapped in a Button: the node holds its own buttons (the permission control).
                    let prompt = rig.prompts.first { $0.seatID == seat.id }
                    SeatNode(
                        seat: seat, isSelected: selection.seatID == seat.id, selectedQItem: selection.qitemID,
                        showsModel: seat.model != nil && seat.model != commonModel,
                        prompt: prompt, linked: prompt?.linkedQItem(in: rig.items)
                    ) { selection.select(seat: seat, in: rig) }
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.height
                    } action: {
                        rig.reportHeight($0, for: seat.id)
                    }
                    .offset(x: frame.minX, y: frame.minY)
                    .accessibilityLabel("\(seat.displayName), \(SeatPhase(seat).label)")
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { selection.clear() }
    }

    /// One label per work wire and next hop (not past hops), placed clear of the seats.
    private var chips: [(wire: Wire, item: QItem, label: String?, anchor: CGPoint)] {
        let seats = Array(layout.seats.values)
        return routes.wires.compactMap { wire in
            if wire.id.hasPrefix("q:"), let item = rig.item(String(wire.id.dropFirst(2))) {
                return (wire, item, nil, chipAnchor(for: wire, avoiding: seats))
            }
            if wire.id.hasPrefix("next:"), let item = rig.item(String(wire.id.dropFirst(5))),
                let hop = rig.nextHop(for: item.id)
            {
                return (wire, item, "next: \(hop.nextStepID)", chipAnchor(for: wire, avoiding: seats))
            }
            return nil
        }
    }

    private var podFrames: [(id: String, title: String, count: Int, frame: CGRect)] {
        var out = graph.pods.compactMap { pod in
            layout.pods[pod.id].map { (pod.id, pod.label, graph.seats(in: pod.id).count, $0) }
        }
        if let frame = layout.pods[unassignedPodID] {
            out.append((unassignedPodID, "Unassigned", 0, frame))
        }
        return out
    }
}

struct PodGroup: View {
    let title: String
    let seatCount: Int

    var body: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(.quaternary.opacity(0.5))
            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            .overlay(alignment: .topLeading) {
                HStack {
                    Text(title.uppercased()).font(.caption.weight(.semibold)).tracking(0.8)
                    Spacer()
                    if seatCount > 0 { Text(seatCount == 1 ? "1 seat" : "\(seatCount) seats").font(.caption) }
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .frame(height: 36)
            }
    }
}

struct DotGrid: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 24
            var dots = Path()
            for x in stride(from: step, to: size.width, by: step) {
                for y in stride(from: step, to: size.height, by: step) {
                    dots.addEllipse(in: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5))
                }
            }
            context.fill(dots, with: .color(.secondary.opacity(0.35)))
        }
        .accessibilityHidden(true)
    }
}
