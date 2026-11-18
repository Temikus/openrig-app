import Foundation

// The daemon's HTTP API is internal and changes between releases.
// Decoders read most fields through `lenient`, so a renamed, missing or retyped
// field becomes nil instead of failing the whole payload.
extension KeyedDecodingContainer {
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

/// Defines string-backed value types that keep unknown values, e.g. a new edge label.
/// Use `struct X: OpenString` with `static let` constants instead of an enum.
public protocol OpenString: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible
where RawValue == String {
    init(rawValue: String)
}

extension OpenString {
    public var description: String { rawValue }
}
