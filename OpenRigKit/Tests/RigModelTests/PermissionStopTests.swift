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

    @Test func missingBlockIsUnavailable() throws {
        let report = try JSONDecoder().decode(SeatStatusReport.self, from: Data("{}".utf8))
        #expect(report.permissionStop.state == .unavailable)
    }
}
