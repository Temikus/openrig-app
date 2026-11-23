import CoreGraphics
import Testing

@testable import RigCanvasLayout

@Suite struct SheenTests {
    let sheen = Sheen()
    let length: CGFloat = 600

    /// Linear interpolation through keyframes, as Core Animation's linear calculation mode does.
    func value(_ frames: [Sheen.Keyframe], at t: CGFloat) -> CGFloat {
        for (a, b) in zip(frames, frames.dropFirst()) where a.time <= t && t <= b.time {
            return b.time == a.time ? b.value : a.value + (b.value - a.value) * (t - a.time) / (b.time - a.time)
        }
        return frames.last!.value
    }

    func clamp(_ x: CGFloat) -> CGFloat { min(max(x, 0), 1) }

    /// With the band's front `distance` along the wire, each layer covers [distance - its length, distance].
    @Test func keyframesFollowTheBandFromSenderToReceiver() {
        let cycle = CGFloat(sheen.duration(length: length)) * sheen.speed
        for i in sheen.layers.indices {
            let k = sheen.keyframes(length: length, layer: i)
            let tail = sheen.layers[i].length
            for distance: CGFloat in [0, 10, 120, 300, 599, 600, 640, 700, 900, 999] {
                let t = distance / cycle
                #expect(abs(value(k.end, at: t) - clamp(distance / length)) < 0.0001, "layer \(i) end at \(distance)")
                #expect(
                    abs(value(k.start, at: t) - clamp((distance - tail) / length)) < 0.0001,
                    "layer \(i) start at \(distance)")
            }
        }
    }

    @Test func keyTimesAreOrderedAndInOneCycle() {
        for i in sheen.layers.indices {
            let k = sheen.keyframes(length: 40, layer: i)
            for frames in [k.start, k.end] {
                let times = frames.map(\.time)
                #expect(times == times.sorted() && times.first == 0 && times.last == 1, "\(times)")
            }
        }
    }

    @Test func bandIsHiddenInTheGap() {
        let longest = sheen.layers.map(\.length).max()!
        let t = (length + longest + 1) / (CGFloat(sheen.duration(length: length)) * sheen.speed)
        for i in sheen.layers.indices {
            let k = sheen.keyframes(length: length, layer: i)
            #expect(value(k.start, at: t) == 1 && value(k.end, at: t) == 1)
        }
    }

    @Test func passesComeAtTheSamePeriodOnShortAndLongWires() {
        #expect(sheen.duration(length: 120) == sheen.period)
        #expect(sheen.duration(length: length) == sheen.period)
    }

    /// Too long to cross in one period: the next pass waits until the longest layer's tail has left the wire.
    @Test func aVeryLongWireWaitsForTheTailToClear() {
        let longest = sheen.layers.map(\.length).max()!
        let long: CGFloat = 2000
        #expect(sheen.duration(length: long) == Double((long + longest) / sheen.speed))
        #expect(sheen.duration(length: long) > sheen.period)
    }

    @Test func phaseIsStablePerWireAndDiffersBetweenWires() {
        let a = sheen.timeOffset(length: length, id: "q:q-b2dc")
        #expect(a == Sheen().timeOffset(length: length, id: "q:q-b2dc"))
        #expect(0 <= a && a < sheen.duration(length: length))
        let all = ["q:q-b2dc", "q:q-875f", "q:q-e6b9", "q:q-0412"].map { sheen.timeOffset(length: length, id: $0) }
        #expect(Set(all).count == 4)
    }

    @Test func lengthIsThePolylineLength() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 30, y: 0), CGPoint(x: 30, y: 40)]
        #expect(Sheen.length(points) == 70)
        #expect(Sheen.length([CGPoint(x: 5, y: 5)]) == 0)
    }
}
