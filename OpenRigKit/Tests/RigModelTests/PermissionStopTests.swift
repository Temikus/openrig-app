import Foundation
import Testing

@testable import RigModel

@Suite struct PermissionStopDecoding {
    @Test func unavailableAsTheDaemonSendsIt() throws {
        let json =
            #"{"permission_stop":{"state":"unavailable","command":"unavailable","origin":"unknown"},"rig_name":"x"}"#
        let report = try JSONDecoder().decode(SeatStatusReport.self, from: Data(json.utf8))
        #expect(report.permissionStop == .unavailable)
        #expect(report.permissionStop.command == nil, "the literal 'unavailable' is not a command")
    }

    // Shape from the daemon's PermissionStopStatus type (permission-stop-observation.d.ts, rig 0.7.11);
    // no live prompt was observed while writing this.
    @Test func observedPrompt() throws {
        let json = #"""
            {"permission_stop":{"state":"request_observed","command":"npx playwright test --ui","origin":"harness",
             "source":"PermissionRequest","observed_at":"2026-11-18T05:30:00.000Z","actor":"main","pending":"unknown"}}
            """#
        let stop = try JSONDecoder().decode(SeatStatusReport.self, from: Data(json.utf8)).permissionStop
        #expect(stop.state == .requestObserved)
        #expect(stop.command == "npx playwright test --ui")
        #expect(stop.observedAt == parseDaemonDate("2026-11-18T05:30:00.000Z"))
        #expect(stop.actor == "main")
    }

    /// Trimmed from `rig seat status orch-lead@openrig-app --json` (rig 0.7.21).
    @Test func launchFolder() throws {
        let json = #"""
            {"permission_stop":{"state":"unavailable","command":"unavailable","origin":"unknown"},
             "seat_ref":"orch-lead@openrig-app","runtime":"claude-code","launch_cwd":"/Users/temikus/iCloud/Code/openrig-app",
             "session_status":"running"}
            """#
        let report = try JSONDecoder().decode(SeatStatusReport.self, from: Data(json.utf8))
        #expect(report.launchCwd == "/Users/temikus/iCloud/Code/openrig-app")
        #expect(try JSONDecoder().decode(SeatStatusReport.self, from: Data("{}".utf8)).launchCwd == nil)
        let blank = #"{"launch_cwd":null}"#
        #expect(try JSONDecoder().decode(SeatStatusReport.self, from: Data(blank.utf8)).launchCwd == nil)
    }

    @Test func missingBlockIsUnavailable() throws {
        let report = try JSONDecoder().decode(SeatStatusReport.self, from: Data("{}".utf8))
        #expect(report.permissionStop.state == .unavailable)
    }
}
