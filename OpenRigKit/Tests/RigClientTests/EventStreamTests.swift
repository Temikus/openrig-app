import Foundation
import Testing

@testable import RigClient

@Suite struct SSEParserTests {
    func parse(_ text: String) -> [SSEParser.Message] {
        var parser = SSEParser()
        // Split on scalars: Swift treats "\r\n" as one Character.
        return text.components(separatedBy: "\n").compactMap {
            parser.feed($0.unicodeScalars.last == "\r" ? String($0.unicodeScalars.dropLast()) : $0)
        }
    }

    @Test func daemonFraming() {
        // The daemon writes data before id.
        let messages = parse("data: {\"type\":\"queue.created\",\"seq\":7}\nid: 7\n\ndata: {\"type\":\"x\"}\nid: 8\n\n")
        #expect(messages.map(\.id) == ["7", "8"])
        #expect(messages[0].data == #"{"type":"queue.created","seq":7}"#)
    }

    @Test func multilineDataCommentsAndCRLF() {
        let messages = parse(": keepalive\r\nevent: ping\r\ndata: a\r\ndata:b\r\n\r\n\n")
        #expect(messages == [SSEParser.Message(id: nil, event: "ping", data: "a\nb")])
    }

    @Test func blankLinesAloneDispatchNothing() {
        #expect(parse("\n\n\nid: 3\n\n").isEmpty)
    }

    @Test func decodeTakesTypeAndRigFromJSON() {
        let event = EventStream.decode(.init(id: "12", event: nil, data: #"{"type":"agent.activity","rigId":"r1"}"#))
        #expect(event.id == 12)
        #expect(event.type == "agent.activity")
        #expect(event.rigId == "r1")
    }

    @Test func decodeFallsBackToSeqWhenIdIsMissing() {
        let event = EventStream.decode(.init(id: nil, event: nil, data: #"{"type":"queue.updated","seq":40}"#))
        #expect(event.id == 40)
        #expect(event.rigId == nil)
    }
}

@Suite(.enabled("needs a running rig daemon") { await LiveDaemon.isRunning() })
struct LiveEventStreamTests {
    let stream = EventStream(baseURL: LiveDaemon.client.baseURL, idleTimeout: 10)

    func first(_ n: Int, replay: Int?, after: Int?) async throws -> [DaemonEvent] {
        var out: [DaemonEvent] = []
        for try await event in stream.connect(replay: replay, lastEventID: after) {
            out.append(event)
            if out.count == n { break }
        }
        return out
    }

    @Test func replayParsesAndResumesWithLastEventID() async throws {
        let recent = try await first(3, replay: 3, after: nil)
        try #require(recent.count == 3, "daemon log has fewer than 3 events")
        let ids = recent.compactMap(\.id)
        #expect(ids == ids.sorted() && Set(ids).count == 3)
        #expect(recent.allSatisfy { !$0.type.isEmpty && $0.type != "message" })

        // Resuming after the first event replays the second one next, whatever `replay` says.
        let resumed = try await first(1, replay: 0, after: ids[0])
        #expect(resumed.first?.id == ids[1])
    }

    @Test(.timeLimit(.minutes(1))) func reportsConnectedBeforeAnyEvent() async throws {
        // A quiet daemon sends headers but no events; the UI must still show "live".
        let first = await withTaskGroup(of: EventStreamUpdate?.self) { group in
            group.addTask {
                for await update in stream.updates() { return update }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
        #expect(first == .connected)
    }
}
