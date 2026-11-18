import Foundation

/// Daemon payloads shared by the test targets. Recorded from rig 0.7.11 with `just record-fixtures`,
/// except graph-edge-cases.json, which is hand-written, and graph-lost.json, recorded from a test rig
/// after its seat's tmux session was killed.
public enum RigFixtures {
    public static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "Fixtures/\(name).json"])
        }
        return try Data(contentsOf: url)
    }

    public static func decode<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: data(name))
    }
}
