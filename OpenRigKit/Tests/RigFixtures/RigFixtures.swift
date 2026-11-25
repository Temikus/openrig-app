import Foundation

/// Daemon payloads shared by the test targets. Recorded from rig 0.7.11 with `just record-fixtures`,
/// except graph-edge-cases.json, which is hand-written, and graph-lost.json, recorded from a test rig
/// after its seat's tmux session was killed. events.json is copied from rig 0.7.22's event log (`events` table), with
/// `seq` and `createdAt` added as the stream adds them and summaries replaced. It has no `queue.unclaimed`: none was logged.
/// transitions-canceled.json is one row's `/api/queue/<id>/transitions` from rig 0.7.22, with notes replaced.
///
/// App contract: app-capabilities, app-credential (token replaced), app-needs-me-empty, app-request-answered,
/// app-result and app-error-404-request-not-found were recorded from rig 0.7.21 with a temporary credential, ask
/// text replaced. The other app-*.json files are written from its core-app.md and daemon source: an open ask,
/// a receipt or a conflict can't be recorded without asking or answering on the person's queue.
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
