import Foundation

/// Display rule for qitem ids, which look like `qitem-20261111110308-f963e5f7`:
/// `q-` plus the last four hex characters. Show the full id on hover.
public func shortQItemID(_ id: String) -> String {
    let tail = id.split(separator: "-").last.map(String.init) ?? id
    return "q-" + String(tail.suffix(4))
}

/// Parses the daemon's timestamps: ISO 8601 with or without fractional seconds,
/// or SQLite's `2026-11-18 03:50:16` (UTC).
public func parseDaemonDate(_ raw: String) -> Date? {
    if let date = try? Date(raw, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) {
        return date
    }
    if let date = try? Date(raw, strategy: .iso8601) { return date }
    let sqlite = Date.ISO8601FormatStyle(dateSeparator: .dash, dateTimeSeparator: .space, timeZone: .gmt)
        .year().month().day().time(includingFractionalSeconds: false)
    return try? Date(raw, strategy: sqlite)
}
