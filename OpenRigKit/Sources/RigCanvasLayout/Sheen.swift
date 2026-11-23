import CoreGraphics
import Foundation

/// A soft band of light that drifts along an in-flight wire from sender to receiver ("Sheen" in PLAN.md §4).
/// Expressed as Core Animation keyframes for `strokeStart` and `strokeEnd`, so the app does no per-frame work.
public struct Sheen: Sendable {
    public struct Layer: Sendable {
        public var length: CGFloat
        public var opacity: Double
        public var width: CGFloat
    }

    /// A point in one cycle: `time` from 0 to 1, `value` a fraction of the wire's length.
    public struct Keyframe: Sendable, Equatable {
        public var time: CGFloat
        public var value: CGFloat
    }

    /// Points per second along the wire.
    public var speed: CGFloat = 90
    /// Seconds from one pass to the next, the same on every wire. A wire too long to cross in that time waits for its
    /// tail to clear the receiver before the next pass.
    public var period: Double = 12
    /// Longest and faintest first; every layer ends at the head, so the short bright ones form its front edge.
    public var layers: [Layer] = [
        Layer(length: 150, opacity: 0.126, width: 5),
        Layer(length: 96, opacity: 0.18, width: 4.5),
        Layer(length: 48, opacity: 0.288, width: 3.5),
        Layer(length: 18, opacity: 0.45, width: 3),
    ]

    public init() {}

    /// Seconds for one cycle on a wire of `length`: the pass, then dark until the next.
    public func duration(length: CGFloat) -> Double {
        max(period, Double((length + (layers.map(\.length).max() ?? 0)) / speed))
    }

    /// Where in its cycle a wire starts, in seconds. Fixed per wire id, so wires don't pulse in step.
    public func timeOffset(length: CGFloat, id: String) -> Double {
        Self.stableFraction(id) * duration(length: length)
    }

    /// One cycle of the layer as linear keyframes. With the head `h` along a wire of length `L`, the layer covers
    /// `[h - layer length, h]`, clamped to the wire; `h` runs from 0 to `duration * speed`.
    public func keyframes(length: CGFloat, layer: Int) -> (start: [Keyframe], end: [Keyframe]) {
        let cycle = CGFloat(duration(length: length)) * speed
        let tail = layers[layer].length
        let end = [Keyframe(time: 0, value: 0), Keyframe(time: length / cycle, value: 1), Keyframe(time: 1, value: 1)]
        let start = [
            Keyframe(time: 0, value: 0), Keyframe(time: tail / cycle, value: 0),
            Keyframe(time: (length + tail) / cycle, value: 1), Keyframe(time: 1, value: 1),
        ]
        return (start, end)
    }

    /// Length of an orthogonal polyline. The drawn path rounds its corners, so it is a few points shorter per bend.
    public static func length(_ points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    /// 0..<1 from the id, the same on every launch (`hashValue` is reseeded per process). FNV-1a.
    static func stableFraction(_ id: String) -> Double {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100_0000_01b3
        }
        return Double(hash % 10_000) / 10_000
    }
}
