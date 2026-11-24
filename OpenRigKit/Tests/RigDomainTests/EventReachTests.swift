import Foundation
import RigFixtures
import Testing

@testable import RigDomain

/// Events recorded from rig 0.7.22's event log, by `seq`, as the stream sends them.
private func recorded() throws -> [Int: EventPlace] {
    let objects = try #require(try JSONSerialization.jsonObject(with: RigFixtures.data("events")) as? [[String: Any]])
    return try objects.reduce(into: [:]) { events, object in
        let seq = try #require(object["seq"] as? Int)
        let type = try #require(object["type"] as? String)
        events[seq] = EventPlace(type: type, payload: try JSONSerialization.data(withJSONObject: object))
    }
}

private enum Seq {
    static let seatHere = 56420, seatDenkeeper = 55574
    static let createdHere = 56412, createdDenkeeper = 56277, createdForMe = 55588
    static let handedOffHere = 56410, handedOffDenkeeper = 55527
    static let claimedHere = 56409, claimedDenkeeper = 55449
    static let updatedHere = 56411, updatedDenkeeper = 55528, updatedBySystem = 56416
    static let answerRecorded = 56344, actionExecuted = 56347
    static let agentHere = 56425, agentDenkeeper = 55518, nodeLaunched = 56388
    static let rigStopped = 55627, snapshot = 56424, watchdog = 55034
}

private let openrigApp = "01M867050G3XH96G7V09102VP6"
private let me: Set<String> = ["artem@external", "human@host"]

private func here(
    seats: Set<String> = [], rows: Set<String> = [], rowsForMe: Set<String> = []
) -> EventContext {
    EventContext(
        rigID: openrigApp, rigName: "openrig-app", seatIDs: seats, holdsRow: rows.contains, addresses: me,
        holdsRowForMe: rowsForMe.contains)
}

@Suite struct EventPlaceTests {
    @Test func decodesThePlacingFieldsOfEachRecordedType() throws {
        let events = try recorded()
        let seat = try #require(events[Seq.seatHere])
        #expect(seat.rigId == nil)
        #expect(seat.sessionName == "dev-b2@openrig-app")
        #expect(seat.seatNodeId == "01M8670D5RRAPYE1KVC91B22PC")

        let created = try #require(events[Seq.createdForMe])
        #expect(created.sourceSession == "orch-lead@token-harness")
        #expect(created.destinationSession == "artem@external")

        let handedOff = try #require(events[Seq.handedOffHere])
        #expect(handedOff.fromSession == "dev-b2@openrig-app")
        #expect(handedOff.toSession == "orch-lead@openrig-app")

        let updated = try #require(events[Seq.updatedBySystem])
        #expect(updated.actorSession == "queue@system")
        #expect(updated.sessions == ["queue@system"])

        let agent = try #require(events[Seq.agentHere])
        #expect(agent.rigId == openrigApp)
        #expect(agent.nodeId != nil)

        for event in events.values where event.type.hasPrefix("queue.") || event.type.hasPrefix("mission_control.") {
            #expect(event.qitemId != nil, "\(event.type)")
        }
    }

    @Test func aPayloadThatIsNotAnObjectPlacesNothing() {
        let event = EventPlace(type: "seat.activity_changed", payload: Data("not json".utf8))
        #expect(event == EventPlace(type: "seat.activity_changed"))
    }
}

@Suite struct EventReachTests {
    @Test func seatActivityRefreshesOnlyItsOwnRig() throws {
        let events = try recorded()
        #expect(eventReach(try #require(events[Seq.seatHere]), in: here()) == [.refreshRig, .pokeTerminals])
        #expect(eventReach(try #require(events[Seq.seatDenkeeper]), in: here()) == [])
    }

    @Test func aSeatNodeIdPlacesAnEventWithoutASession() {
        let event = EventPlace(type: "seat.activity_changed", seatNodeId: "seat-1")
        #expect(eventReach(event, in: here(seats: ["seat-1"])) == [.refreshRig, .pokeTerminals])
        #expect(eventReach(event, in: here(seats: ["seat-2"])) == [])
    }

    @Test func queueEventsArePlacedByTheSessionsTheyName() throws {
        let events = try recorded()
        for seq in [Seq.createdHere, Seq.handedOffHere, Seq.claimedHere, Seq.updatedHere] {
            #expect(eventReach(try #require(events[seq]), in: here()) == [.refreshRig], "\(seq)")
        }
        for seq in [Seq.createdDenkeeper, Seq.handedOffDenkeeper, Seq.claimedDenkeeper, Seq.updatedDenkeeper] {
            #expect(eventReach(try #require(events[seq]), in: here()) == [], "\(seq)")
        }
    }

    /// `queue@system` sits on no rig, so only the row id can place this one.
    @Test func anUpdateByTheSystemIsPlacedByItsRow() throws {
        let event = try #require(try recorded()[Seq.updatedBySystem])
        let row = try #require(event.qitemId)
        #expect(eventReach(event, in: here(rows: [row])) == [.refreshRig])
        #expect(eventReach(event, in: here()) == [])
    }

    @Test func aNewRowForThePersonRereadsTheirRowsOnly() throws {
        let event = try #require(try recorded()[Seq.createdForMe])
        #expect(eventReach(event, in: here()) == [.refreshRowsForMe])
        let someoneElse = EventContext(rigID: openrigApp, rigName: "openrig-app", addresses: ["human@host"])
        #expect(eventReach(event, in: someoneElse) == [])
    }

    @Test func theSessionsNamedOutrankTheActor() {
        let event = EventPlace(
            type: "queue.created", sourceSession: "a@denkeeper", destinationSession: "b@denkeeper",
            actorSession: "c@openrig-app")
        #expect(eventReach(event, in: here()) == [])
    }

    @Test func anAnswerByThePersonRereadsWhatHoldsTheRow() throws {
        let event = try #require(try recorded()[Seq.answerRecorded])
        let row = try #require(event.qitemId)
        #expect(eventReach(event, in: here()) == [])
        #expect(eventReach(event, in: here(rowsForMe: [row])) == [.refreshRowsForMe])
        #expect(eventReach(event, in: here(rows: [row], rowsForMe: [row])) == [.refreshRig, .refreshRowsForMe])
    }

    /// Only `queue.*` events re-read the rows for the person; the answer's own `queue.answer_recorded` does.
    @Test func aMissionControlActionRefreshesTheRigThatHoldsItsRow() throws {
        let event = try #require(try recorded()[Seq.actionExecuted])
        let row = try #require(event.qitemId)
        #expect(eventReach(event, in: here(rows: [row], rowsForMe: [row])) == [.refreshRig])
        #expect(eventReach(event, in: here()) == [])
    }

    @Test func eventsWithARigIdRefreshThatRigOnly() throws {
        let events = try recorded()
        #expect(eventReach(try #require(events[Seq.agentHere]), in: here()) == [.refreshRig])
        #expect(eventReach(try #require(events[Seq.nodeLaunched]), in: here()) == [.refreshRig])
        #expect(eventReach(try #require(events[Seq.agentDenkeeper]), in: here()) == [])
    }

    @Test func rigEventsRereadTheRigList() throws {
        let event = try #require(try recorded()[Seq.rigStopped])
        #expect(eventReach(event, in: here()) == [.refreshRigList])
        let selected = EventContext(rigID: event.rigId, rigName: "token-harness", addresses: me)
        #expect(eventReach(event, in: selected) == [.refreshRigList, .refreshRig])
    }

    @Test func snapshotsAndWatchdogsChangeNothing() throws {
        let events = try recorded()
        #expect(eventReach(try #require(events[Seq.snapshot]), in: here()) == [])
        #expect(eventReach(try #require(events[Seq.watchdog]), in: here()) == [])
    }

    @Test func anEventThatNamesNothingRefreshesTheSelectedRig() {
        #expect(eventReach(EventPlace(type: "pod.created"), in: here()) == [.refreshRig])
        #expect(eventReach(EventPlace(type: "seat.activity_changed"), in: here()) == [.refreshRig, .pokeTerminals])
    }

    @Test func withNoRigSelectedNothingRefreshesARig() throws {
        let none = EventContext(rigID: nil, rigName: nil, addresses: me)
        #expect(eventReach(try #require(try recorded()[Seq.seatHere]), in: none) == [])
        #expect(eventReach(EventPlace(type: "pod.created"), in: none) == [])
    }

    /// The recorded log with openrig-app selected: 7 of its 20 events refresh the rig, and only the rig event
    /// re-reads the rig list.
    @Test func overTheRecordedLog() throws {
        let events = try recorded().values
        let reaches = events.map { eventReach($0, in: here()) }
        #expect(reaches.filter { $0.contains(.refreshRig) }.count == 7)
        #expect(reaches.filter { $0.contains(.refreshRigList) }.count == 1)
        #expect(reaches.filter { $0.contains(.refreshRowsForMe) }.count == 1)
    }
}
