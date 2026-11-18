import Foundation
import RigModel
import Testing

@testable import RigDomain

@Suite struct PromptTests {
    let seen = Date(timeIntervalSince1970: 1_800_000_000)
    let seat = Seat(
        id: "s1", logicalId: "review.design", sessionName: "review-design@r",
        currentQItems: [QItemRef(id: "q-work")])

    var stop: PermissionStop {
        PermissionStop(state: .requestObserved, command: "npx playwright test --ui", observedAt: seen, actor: "main")
    }

    @Test func instanceOnlyForAnOpenPrompt() throws {
        let instance = try #require(PromptInstance(seat: seat, stop: stop))
        #expect(instance.command == "npx playwright test --ui")
        #expect(instance.session == "review-design@r")
        #expect(PromptInstance(seat: seat, stop: .unavailable) == nil)
        #expect(
            PromptInstance(seat: seat, stop: PermissionStop(state: .completed, command: "x", observedAt: seen)) == nil)
        #expect(
            PromptInstance(seat: Seat(id: "s2", logicalId: "x"), stop: stop) == nil, "no session, nothing to answer")
    }

    @Test func staleness() throws {
        let instance = try #require(PromptInstance(seat: seat, stop: stop))
        #expect(instance.check(against: stop) == .same)

        var other = stop
        other.command = "rm -rf build"
        #expect(instance.check(against: other) == .changed, "different command: never answer it blind")

        var later = stop
        later.observedAt = seen + 30
        #expect(instance.check(against: later) == .changed, "same command, new prompt: still a different prompt")

        #expect(instance.check(against: .unavailable) == .gone)
        #expect(
            instance.check(against: PermissionStop(state: .completed, command: stop.command, observedAt: seen)) == .gone
        )
    }

    @Test func promptLinksToTheSeatsCurrentWork() throws {
        let instance = try #require(PromptInstance(seat: seat, stop: stop))
        let rows = [
            item("q-work", .inProgress, from: "lead@r", to: "review-design@r"),
            item("q-other", .inProgress, from: "lead@r", to: "dev@r"),
        ]
        #expect(instance.linkedQItem(in: rows)?.id == "q-work")
        #expect(instance.linkedQItem(in: []) == nil)
    }

    @Test func needsYouListsPromptsFirstThenHeldRows() throws {
        let instance = try #require(PromptInstance(seat: seat, stop: stop))
        let rows = [
            item("q-work", .inProgress, from: "lead@r", to: "review-design@r"),
            item("q-held", .blocked, from: "lead@r", to: "dev@r", blockedOn: "external:decision"),
        ]
        let entries = needsYouEntries(prompts: [instance], seats: [], items: rows)
        #expect(entries.map(\.id) == ["prompt:s1", "qitem:q-held"])
        if case .prompt(_, let linked) = entries[0] {
            #expect(linked?.id == "q-work")
        } else {
            Issue.record("first entry should be the prompt")
        }
    }

    @Test func heldRowOwnedByAPromptingSeatIsNotListedTwice() throws {
        let held = item("q-held", .blocked, from: "lead@r", to: "review-design@r", blockedOn: "external:prompt")
        let s = Seat(id: "s1", logicalId: "review.design", sessionName: "review-design@r", currentQItems: [])
        let entries = needsYouEntries(
            prompts: [try #require(PromptInstance(seat: s, stop: stop))], seats: [], items: [held])
        #expect(entries.count == 1)
        if case .prompt(_, let linked) = entries[0] { #expect(linked?.id == "q-held") }
    }
}
