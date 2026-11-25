/// Takes the tmux client's own terminal queries out of its output, so the view never answers them.
///
/// The client asks as it attaches (seen live, tmux 3.8): DA1 `CSI c`, DA2 `CSI > c`, XTVERSION `CSI > q`, the
/// foreground and background colours `OSC 10;?` and `OSC 11;?`, the size `CSI 18 t` and `CSI 14 t`, and the
/// theme `CSI ? 996 n`. That is when the tile is focused, but a view only subscribes when Type mode starts, and
/// it gets that output replayed from the backlog. SwiftTerm then answered seconds late, and tmux, which takes an
/// answer only while it is waiting for one, passed the late answers to the pane as if they were typed. Nobody
/// answers these in time anyway, so tmux falls back to its terminfo either way.
///
/// tmux answers the pane's own queries itself while `allow-passthrough` is off. With it on, a pane program's query
/// wrapped in `DCS tmux;` reaches the client bare, this filter drops it, and the program waits for a reply that
/// never comes.
struct TerminalQueryFilter {
    /// The start of an escape sequence cut off at the end of a chunk, held for the next one.
    private var pending: [UInt8] = []
    /// A sequence longer than this isn't one of the queries, so it is passed on rather than held.
    private static let longestHeld = 64

    mutating func filter(_ chunk: ArraySlice<UInt8>) -> [UInt8] {
        let data = pending + chunk
        pending = []
        var out: [UInt8] = []
        out.reserveCapacity(data.count)
        var i = 0
        while i < data.count {
            guard data[i] == 0x1B else {
                out.append(data[i])
                i += 1
                continue
            }
            switch Self.sequence(in: data, at: i) {
            case .incomplete where data.count - i <= Self.longestHeld:
                pending = Array(data[i...])
                return out
            case .query(let end):
                i = end
            case .other(let end):
                out += data[i..<end]
                i = end
            case .incomplete:
                out.append(data[i])
                i += 1
            }
        }
        return out
    }

    private enum Sequence {
        /// One of the client's queries, ending before `end`.
        case query(end: Int)
        /// Anything else: passed on as it is.
        case other(end: Int)
        /// The chunk ends inside it.
        case incomplete
    }

    private static let csiQueries: Set<String> = ["c", "0c", ">c", ">0c", ">q", ">0q", "14t", "16t", "18t", "?996n"]
    private static let oscQueries: Set<String> = ["10;?", "11;?"]

    private static func sequence(in data: [UInt8], at start: Int) -> Sequence {
        guard start + 1 < data.count else { return .incomplete }
        switch data[start + 1] {
        case UInt8(ascii: "["):
            // Parameters and intermediates (0x20–0x3F), then one final byte (0x40–0x7E).
            var j = start + 2
            while j < data.count, (0x20...0x3F).contains(data[j]) { j += 1 }
            guard j < data.count else { return .incomplete }
            guard (0x40...0x7E).contains(data[j]) else { return .other(end: j) }
            let body = String(decoding: data[(start + 2)...j], as: UTF8.self)
            return csiQueries.contains(body) ? .query(end: j + 1) : .other(end: j + 1)
        case UInt8(ascii: "]"):
            // Ends with BEL or ST (ESC \).
            var j = start + 2
            while j < data.count {
                if data[j] == 0x07 {
                    let body = String(decoding: data[(start + 2)..<j], as: UTF8.self)
                    return oscQueries.contains(body) ? .query(end: j + 1) : .other(end: j + 1)
                }
                if data[j] == 0x1B {
                    guard j + 1 < data.count else { return .incomplete }
                    guard data[j + 1] == UInt8(ascii: "\\") else { return .other(end: j) }
                    let body = String(decoding: data[(start + 2)..<j], as: UTF8.self)
                    return oscQueries.contains(body) ? .query(end: j + 2) : .other(end: j + 2)
                }
                j += 1
            }
            return .incomplete
        default:
            return .other(end: start + 1)
        }
    }
}
