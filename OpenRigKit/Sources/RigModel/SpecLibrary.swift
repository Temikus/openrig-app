import Foundation

/// One row of `GET /api/specs/library` (same shape as `rig specs ls --json`).
public struct SpecEntry: Decodable, Sendable, Identifiable, Hashable {
    public var id: String
    public var kind: String
    public var name: String
    public var summary: String?
    /// "builtin" (ships with OpenRig) or "user_file" (the person's library).
    public var sourceType: String
    public var sourcePath: String
    /// A managed app: it starts services (such as Vault), not just seats.
    public var hasServices: Bool?

    public init(
        id: String, kind: String = "rig", name: String, summary: String? = nil, sourceType: String = "builtin",
        sourcePath: String = "", hasServices: Bool? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.summary = summary
        self.sourceType = sourceType
        self.sourcePath = sourcePath
        self.hasServices = hasServices
    }

    public var isBuiltin: Bool { sourceType == "builtin" }
}

/// `GET /api/specs/library/<id>/review`: the spec's own text and where it lives.
public struct SpecReview: Decodable, Sendable, Equatable {
    public var name: String
    public var summary: String?
    public var raw: String
    /// The spec file itself.
    public var sourcePath: String
}
