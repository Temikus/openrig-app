import Foundation
import Testing

@testable import RigClient

@Suite struct RigActionArgvTests {
    @Test func send() {
        let a = RigAction.send(session: "dev-b1@denkeeper", text: "please rebase; then `rm -rf` nothing")
        #expect(a.arguments == ["send", "dev-b1@denkeeper", "please rebase; then `rm -rf` nothing", "--json"])
        #expect(a.stdin == nil, "argv goes straight to exec, never through a shell")
    }

    @Test func create() {
        let a = RigAction.create(
            destination: "dev-b1@denkeeper", summary: "Fix login", body: "Details\nhere", priority: .urgent)
        #expect(
            a.arguments == [
                "queue", "create", "--destination", "dev-b1@denkeeper", "--summary", "Fix login",
                "--priority", "urgent", "--body-file", "-", "--json",
            ])
        #expect(a.stdin == "Details\nhere")
    }

    @Test func createWithoutBodyUsesTheSummary() {
        let a = RigAction.create(destination: "x@r", summary: "Do it", body: "", priority: .routine)
        #expect(a.stdin == "Do it", "the daemon requires a body")
    }

    @Test func handoff() {
        let a = RigAction.handoff(id: "qitem-1", to: "rev@r", summary: "Review it", body: nil)
        #expect(a.arguments == ["queue", "handoff", "qitem-1", "--to", "rev@r", "--summary", "Review it", "--json"])
        let withBody = RigAction.handoff(id: "qitem-1", to: "rev@r", summary: "Review it", body: "notes")
        #expect(withBody.arguments.suffix(3) == ["--body-file", "-", "--json"])
        #expect(withBody.stdin == "notes")
    }

    @Test func block() {
        // Not --summary: rig 0.7.11 refuses it on every park but a registered human seat
        // (summary_evidence_not_persistable, seen live for external: and operator-human@kernel).
        let a = RigAction.block(id: "qitem-1", on: "external:pr-decision", wakeAfter: "1h", note: "Waiting on review")
        #expect(
            a.arguments == [
                "queue", "block", "qitem-1", "--on", "external:pr-decision", "--wake-after", "1h",
                "--note", "Waiting on review", "--json",
            ])
        let bare = RigAction.block(id: "qitem-1", on: "qitem-2", wakeAfter: nil, note: nil)
        #expect(bare.arguments == ["queue", "block", "qitem-1", "--on", "qitem-2", "--json"])
    }

    @Test func close() {
        let plain = RigAction.close(id: "qitem-1", reason: .noFollowOn, target: nil, resolution: "Shipped")
        #expect(
            plain.arguments == [
                "queue", "update", "qitem-1", "--state", "done", "--closure-reason", "no-follow-on",
                "--resolution", "Shipped", "--json",
            ])
        let superseded = RigAction.close(id: "qitem-1", reason: .superseded, target: "qitem-9", resolution: nil)
        #expect(superseded.arguments.contains("--closure-target"))
        #expect(superseded.arguments.contains("qitem-9"))
    }

    @Test func closeReasonsThatNeedATarget() {
        #expect(CloseReason.superseded.needsTarget)
        #expect(CloseReason.escalation.needsTarget)
        #expect(!CloseReason.noFollowOn.needsTarget)
        #expect(!CloseReason.allCases.map(\.rawValue).contains("handed_off_to"), "handoffs go through Hand off")
    }

    @Test func noteAndDeadline() {
        #expect(
            RigAction.note(id: "q", text: "checked in").arguments == [
                "queue", "update", "q", "--note", "checked in", "--json",
            ])
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(
            RigAction.newDeadline(id: "q", at: at).arguments == [
                "queue", "update", "q", "--closure-required-at", "2027-01-15T08:00:00Z", "--json",
            ])
    }

    @Test func answerPromptIsAuditedInteraction() {
        let a = RigAction.answerPrompt(
            session: "rd@r", keys: "1", reason: "OpenRig.app: allow once npx playwright test")
        #expect(
            a.arguments == [
                "send", "rd@r", "1", "--dangerously-interact", "--reason",
                "OpenRig.app: allow once npx playwright test",
                "--json",
            ])
    }

    @Test func resolve() {
        #expect(
            RigAction.resolve(id: "q", decision: "allow once: ls").arguments == [
                "queue", "resolve", "q", "--decision", "allow once: ls", "--json",
            ])
    }

    @Test func clearAttention() {
        #expect(
            RigAction.clearAttention(session: "s@r", reason: "declined").arguments == [
                "seat", "clear-attention", "s@r", "--reason", "declined", "--json",
            ])
    }

    @Test func startDaemonHasNoJSONFlag() {
        #expect(RigAction.startDaemon.arguments == ["daemon", "start"], "rig daemon start doesn't take --json")
    }

    @Test func displayCommandQuotesForTheUser() {
        let a = RigAction.send(session: "b1@r", text: "it's done")
        #expect(a.displayCommand == "rig send b1@r 'it'\\''s done' --json")
    }
}

@Suite struct RigCLITests {
    @Test func locatesRigOrReportsMissing() {
        let missing = RigCLI.locate(searchPaths: ["/nonexistent/rig"])
        #expect(missing == nil)
    }

    @Test func environmentStampsTheHumanSeatAndAPath() {
        let env = RigCLI.environment(base: ["HOME": "/Users/x", "PATH": "/usr/bin"], actor: "operator-human@kernel")
        #expect(env["OPENRIG_SESSION_NAME"] == "operator-human@kernel")
        #expect(env["PATH"]?.hasPrefix("/opt/homebrew/bin:") == true, "Node's shebang needs Homebrew on PATH")
        #expect(env["NO_COLOR"] == "1")
    }

    @Test func failureCarriesStderr() async throws {
        let cli = RigCLI(executable: URL(filePath: "/bin/sh"), actor: "operator-human@kernel")
        // /bin/sh stands in for rig: exercises stdin, exit codes and stderr capture end to end.
        let result = try await cli.run(arguments: ["-c", "cat; echo oops >&2; exit 3"], stdin: "hello")
        #expect(result.status == 3)
        #expect(result.stdout == "hello")
        #expect(result.stderr == "oops")
        #expect(!result.succeeded)
    }
}

/// Read-only: the CLI accepts the app's identity. Writes are in LiveWriteTests (`just test-live`).
@Suite(
    .enabled("needs rig and a running daemon") {
        guard RigCLI.locate() != nil else { return false }
        return (try? await DaemonHTTP(baseURL: DaemonLocator().locate().baseURL, timeout: 2).health()) != nil
    })
struct LiveCLITests {
    @Test func whoamiAsTheHumanSeat() async throws {
        let cli = try #require(RigCLI.locate(actor: "operator-human@kernel"))
        let result = try await cli.run(arguments: ["queue", "whoami", "--json"])
        #expect(result.succeeded, "\(result.stderr)")
        #expect(result.stdout.contains("\"session\":\"operator-human@kernel\""))
    }
}
