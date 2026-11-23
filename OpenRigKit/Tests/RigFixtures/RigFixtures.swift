import Foundation

/// Daemon payloads shared by the test targets. Recorded from rig 0.7.11 with `just record-fixtures`,
/// except graph-edge-cases.json, which is hand-written, and graph-lost.json, recorded from a test rig
/// after its seat's tmux session was killed. events.json is copied from rig 0.7.22's event log (`events` table), with
/// `seq` and `createdAt` added as the stream adds them and summaries replaced. It has no `queue.unclaimed`: none was logged.
/// transitions-canceled.json is one row's `/api/queue/<id>/transitions` from rig 0.7.22, with notes replaced.
///
/// Unverified: the app-*.json files are written from rig 0.7.21's core-app.md and its daemon source
/// (routes/core-app.js, domain/core-app-job.js), not recorded. Replace them with recordings when a credential may be issued.
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
