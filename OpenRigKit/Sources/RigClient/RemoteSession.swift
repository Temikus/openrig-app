import Foundation
import Observation
import RigModel

/// The phone's side of a pairing: the stored code, where the phone stands with the Mac, the last list it read, and
/// the answers it is writing and has sent.
@Observable @MainActor
public final class RemoteSession {
    public private(set) var pairing: RemotePairing?
    /// Nil until the first check after pairing or launch finishes.
    public private(set) var status: RemoteStatus?
    public private(set) var checking = false
    /// The last list read. Kept while the Mac is out of reach, marked with `lastReached`.
    public private(set) var needs: AppNeedsMe?
    public private(set) var lastReached: Date?
    /// Why the last link didn't pair, or why Unpair failed.
    public var pairingError: String?
    /// A link opened from outside the app, waiting for the person's yes.
    public var pendingCode: PairingCode?
    /// Replaces the status after each real check, keeping what was read. For headless captures.
    public var statusOverride: RemoteStatus?
    /// Half-made answers by ask, kept while the person moves around. Memory only.
    public private(set) var drafts = AppAnswerDrafts()
    /// Asks being sent now.
    public private(set) var sending: Set<String> = []
    /// What was sent on each ask and what the daemon said, by ask id. The ask leaves the list; this stays.
    public private(set) var sent: [String: SentAnswer] = [:]

    private let store: any PairingStore
    private let outbox: any AnswerOutbox
    private let answerRetryDelay: Duration
    private let connect: @Sendable (PairingCode) async -> RemoteConnector.Outcome
    /// The client of the endpoint that last answered. Nil while not connected.
    private var client: AppClient?
    /// Outbox entries being sent now, so a check doesn't resend them alongside.
    private var inFlight: Set<String> = []
    /// Asks whose unconfirmed answer just landed with more of the draft still to send.
    private var continuing: Set<String> = []

    public init(
        store: any PairingStore, outbox: any AnswerOutbox = MemoryAnswerOutbox(),
        answerRetryDelay: Duration = .seconds(1),
        connect: @escaping @Sendable (PairingCode) async -> RemoteConnector.Outcome
    ) {
        self.store = store
        self.outbox = outbox
        self.answerRetryDelay = answerRetryDelay
        self.connect = connect
        pairing = try? store.load()
    }

    public convenience init(store: any PairingStore, outbox: any AnswerOutbox, connector: RemoteConnector) {
        self.init(store: store, outbox: outbox, connect: { await connector.connect($0) })
    }

    public var macName: String { pairing?.code.name ?? "Your Mac" }

    /// The endpoint in use, or the first one the code lists.
    public var address: String? {
        if case .connected(let endpoint) = status { return endpoint.description }
        return pairing.flatMap { RemoteEndpoint.all(in: $0.code).first?.description }
    }

    /// The asks Needs you lists, or nil when a state screen takes its place. A list read before the Mac went out of
    /// reach stays, marked with `lastReached`.
    public var shownRequests: [AppRequest]? {
        switch status {
        case nil, .unreachable: needs?.requests
        case .connected: needs?.requests ?? []
        case .localNetworkDenied, .unpaired, .unsupportedDaemon, .noSafeAddress: nil
        }
    }

    /// `artem@external` shows as `artem`.
    public var answeringAs: String? { pairing.map { String($0.code.actor.prefix { $0 != "@" }) } }

    // MARK: Pairing

    /// A scan or paste inside the app: the person chose it, so it pairs at once.
    public func pair(link: String) {
        do {
            save(try PairingCode(parsing: link))
        } catch {
            pairingError = Self.message(for: error)
        }
    }

    /// A link from another app or a web page. Anyone can send one, so it pairs only after the person confirms.
    public func receive(openedLink link: String) {
        do {
            pendingCode = try PairingCode(parsing: link)
        } catch {
            pairingError = Self.message(for: error)
        }
    }

    public func confirmPending() {
        if let pendingCode { save(pendingCode) }
        pendingCode = nil
    }

    /// A failed save leaves the old pairing in place.
    private func save(_ code: PairingCode) {
        let new = RemotePairing(code: code, pairedAt: .now)
        do {
            try store.save(new)
        } catch {
            pairingError = "This phone couldn't keep the pairing in its Keychain. Try again."
            return
        }
        // Answers held back for the old pairing never go to the new one.
        if pairing?.code.credentialID != code.credentialID { try? outbox.removeAll() }
        pairing = new
        forgetReads()
        pairingError = nil
        Task { await refresh() }
    }

    /// If the Keychain won't let go, the token is still on the phone: say so and stay paired.
    public func unpair() {
        do {
            try store.delete()
        } catch {
            pairingError =
                "This phone couldn't remove the pairing from its Keychain, so it still holds the key. Try again, or delete the app."
            return
        }
        // The person unpaired to stop: nothing held back goes later, to this Mac or another.
        try? outbox.removeAll()
        pairing = nil
        forgetReads()
        pairingError = nil
    }

    private func forgetReads() {
        status = nil
        needs = nil
        lastReached = nil
        client = nil
        drafts = AppAnswerDrafts()
        sent = [:]
    }

    // MARK: Checking

    /// Checks the current pairing. If the pairing changes while a check runs, that check's result is dropped and the
    /// new pairing is checked, so a new pairing never waits on an old one.
    public func refresh() async {
        guard !checking else { return }
        checking = true
        while let current = pairing, await !check(current) {}
        // An unconfirmed answer landed with more to send: read again, so the rest goes at the new revision.
        if !continuing.isEmpty {
            while let current = pairing, await !check(current) {}
        }
        checking = false
        await continueChains()
    }

    /// Refreshes every `interval`, and at once on each event from the Mac, until cancelled. Run it while the app is
    /// open.
    public func keepFresh(every interval: Duration = .seconds(5)) async {
        await withDiscardingTaskGroup { group in
            group.addTask { await self.poll(every: interval) }
            group.addTask { await self.listen() }
        }
    }

    private func poll(every interval: Duration) async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: interval)
        }
    }

    /// Events carry no data: each one means "read again". A dropped stream reconnects after a pause.
    private func listen() async {
        while !Task.isCancelled {
            if let client {
                do {
                    for try await event in client.events() where event != .heartbeat {
                        await refresh()
                    }
                } catch {}
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    /// False when the pairing changed underneath, so nothing was applied.
    private func check(_ checked: RemotePairing) async -> Bool {
        let outcome = await connect(checked.code)
        guard pairing == checked else { return false }
        var next = outcome.status
        var read: AppNeedsMe?
        if let client = outcome.client {
            do {
                read = try await client.needsMe()
            } catch .unpaired {
                next = .unpaired
            } catch {
                next = .unreachable(detail: "\(error)")
            }
            guard pairing == checked else { return false }
        }
        client = read == nil ? nil : outcome.client
        if let read {
            needs = read
            lastReached = .now
        }
        status = statusOverride ?? next
        if let client { await resendPending(with: client) }
        return true
    }

    // MARK: Answering

    public func draft(for request: AppRequest) -> AppAnswerDraft { drafts.draft(for: request) }

    public func setDraft(_ draft: AppAnswerDraft, for request: AppRequest) { drafts.set(draft, for: request.id) }

    /// Drops an ask's record, so its question screen shows the questions again.
    public func forgetSent(_ id: String) { sent[id] = nil }

    /// Sends the draft: one submission per open question, in order, each at the revision the last receipt gave. A
    /// typed reply is one submission. Each is saved before it's sent, so an uncertain end can be resent unchanged.
    public func send(_ request: AppRequest) async { await send(request, after: []) }

    /// `earlier`: lines already sent on this ask, when an unconfirmed answer has landed and the rest now follows.
    private func send(_ request: AppRequest, after earlier: [SentAnswer.Line]) async {
        guard !sending.contains(request.id), let client, let pairing,
            let submissions = draft(for: request).submissions(for: request), var revision = request.decisionRevision
        else { return }
        sending.insert(request.id)

        var lines = SentAnswer.lines(submissions, in: request)
        var outcome = SentAnswer.Outcome.stillOpen
        for (index, submission) in submissions.enumerated() {
            let binding = submission.binding(on: request, at: revision, as: pairing.code.actor)
            let pending: PendingAnswer
            do {
                pending = PendingAnswer(
                    id: AppAnswerID.random(), credentialID: pairing.code.credentialID, requestID: request.id,
                    body: try AppClient.body(binding))
                try outbox.add(pending)
            } catch {
                outcome = .failed("This phone couldn't save the answer before sending it, so it didn't send it.")
                break
            }
            switch await deliver(pending, with: client, attempts: 3) {
            case .receipt(let receipt):
                lines[index].state = receipt.fate == .incomplete ? .unconfirmed : .sent
                if case .partial = receipt.fate, index < submissions.count - 1,
                    let after = receipt.submission.revisionAfter
                {
                    revision = after
                    continue
                }
                outcome = SentAnswer.Outcome(receipt.fate)
            case .refused(let error):
                outcome = SentAnswer.Outcome(error)
                if outcome == .notFinished { lines[index].state = .unconfirmed }
            }
            break
        }

        sent[request.id] = SentAnswer(outcome: outcome, answers: earlier + lines, asker: request.asker, at: .now)
        switch outcome {
        // The picks still matter: after a look, or for the answers that wait on an unconfirmed one.
        case .failed, .changed, .stillOpen, .notFinished: break
        default: drafts.clear(request.id)
        }
        sending.remove(request.id)
        await refresh()
    }

    private enum Delivery {
        case receipt(AppAnswerReceipt)
        case refused(AppError)
    }

    /// Leaves the entry in the outbox only when the same id may still finish it.
    private func deliver(_ pending: PendingAnswer, with client: AppClient, attempts: Int) async -> Delivery {
        inFlight.insert(pending.id)
        defer { inFlight.remove(pending.id) }
        do {
            let receipt = try await client.answer(
                id: pending.id, body: pending.body, attempts: attempts, retryDelay: answerRetryDelay)
            if receipt.fate != .incomplete { try? outbox.remove(id: pending.id) }
            return .receipt(receipt)
        } catch {
            if !error.retrySameSubmission { try? outbox.remove(id: pending.id) }
            return .refused(error)
        }
    }

    /// Sends again, with the same id and bytes, what an earlier attempt couldn't confirm. An entry from another
    /// pairing is dropped unsent. An ask's record follows; if its answer landed with more to send, the rest goes
    /// after a fresh read (`refresh`).
    private func resendPending(with client: AppClient) async {
        guard let pending = try? outbox.load(), let credential = pairing?.code.credentialID else { return }
        for answer in pending where !inFlight.contains(answer.id) {
            guard answer.credentialID == credential else {
                try? outbox.remove(id: answer.id)
                continue
            }
            let delivery = await deliver(answer, with: client, attempts: 1)
            guard var record = sent[answer.requestID], record.outcome == .notFinished else { continue }
            switch delivery {
            case .receipt(let receipt) where receipt.fate != .incomplete:
                if let i = record.answers.firstIndex(where: { $0.state == .unconfirmed }) {
                    record.answers[i].state = .sent
                }
                if case .partial = receipt.fate, record.answers.contains(where: { $0.state == .notSent }) {
                    // The rest is sent again from the draft, at a fresh revision.
                    record.answers.removeAll { $0.state == .notSent }
                    continuing.insert(answer.requestID)
                } else {
                    record.outcome = SentAnswer.Outcome(receipt.fate)
                }
            case .receipt: break
            case .refused(let error): record.outcome = SentAnswer.Outcome(error)
            }
            sent[answer.requestID] = record
        }
    }

    /// After a fresh read, sends the rest of each ask whose unconfirmed answer just landed.
    private func continueChains() async {
        let ids = continuing
        continuing = []
        for id in ids {
            guard let earlier = sent[id]?.answers else { continue }
            if let request = needs?.requests.first(where: { $0.id == id }),
                draft(for: request).submissions(for: request) != nil
            {
                await send(request, after: earlier)
            } else {
                sent[id]?.outcome = .stillOpen
            }
        }
    }

    public static func message(for error: PairingCodeError) -> String {
        switch error {
        case .malformed: "That isn't an OpenRig pairing link. Copy the whole link under the code on your Mac."
        case .newerVersion, .noKnownReach: "This link comes from a newer OpenRig. Update this app, then pair again."
        case .unsupportedHost(let host): "This link points to \(host), which this app won't connect to."
        }
    }
}

/// A record of what the phone sent on one ask and what the daemon said.
public struct SentAnswer: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        /// Returned to the asker as a new row.
        case returned
        /// Saved on the ask, which still waits: no agent could read it yet. Nothing needs sending again.
        case kept(message: String?)
        /// Someone answered first. Nothing new was sent.
        case alreadyAnswered
        /// Some answers went in, but the ask still has open questions.
        case stillOpen
        /// The ask changed before the answers went in. It needs a fresh look.
        case changed
        /// The ask's content was erased.
        case erased
        /// Not confirmed. The phone resends the same answer on each check until it is.
        case notFinished
        case failed(String)

        init(_ fate: AppAnswerFate) {
            switch fate {
            case .returned: self = .returned
            case .alreadyAnswered: self = .alreadyAnswered
            case .answeredInPlace(let message): self = .kept(message: message)
            case .partial: self = .stillOpen
            case .incomplete: self = .notFinished
            case .conflict: self = .changed
            case .sourceUnavailable: self = .erased
            case .unknown(let state): self = .failed("The Mac answered with \"\(state)\".")
            }
        }

        init(_ error: AppError) {
            if error.retrySameSubmission {
                self = .notFinished
                return
            }
            switch error {
            case .refused(409, "answer_already_returned", _), .refused(409, "answer_already_finalized", _):
                self = .alreadyAnswered
            case .refused(409, _, _): self = .changed
            case .refused(_, let code, _): self = .failed("The Mac refused it (\(code ?? "no reason given")).")
            case .unpaired: self = .failed("The Mac no longer accepts this phone.")
            case .unsupportedDaemon: self = .failed("The Mac can't take answers from this app.")
            case .decoding: self = .failed("The Mac's reply couldn't be read.")
            case .unreachable(let message): self = .failed(message)
            }
        }
    }

    public struct Line: Sendable, Equatable {
        public var question: String
        public var answer: String
        /// Lines start as not sent and change as receipts come back.
        public var state: State = .notSent

        public enum State: Sendable, Equatable {
            case sent
            /// Sent, but the Mac's receipt didn't come back. The phone resends it.
            case unconfirmed
            /// Waits on an earlier answer; it goes once that one is confirmed.
            case notSent
        }
    }

    public var outcome: Outcome
    public var answers: [Line]
    public var asker: String?
    public var at: Date

    /// The question and the chosen option's label, or the person's own words.
    static func lines(_ submissions: [AppAnswerDraft.Submission], in request: AppRequest) -> [Line] {
        submissions.map { submission in
            let question = request.questions.first { $0.id == submission.questionID }
            switch submission.form {
            case .option(let id):
                return Line(
                    question: question?.question ?? submission.questionID,
                    answer: question?.options.first { $0.id == id }?.label ?? id)
            case .typedReply(let text):
                return Line(question: "In your own words", answer: text)
            }
        }
    }
}
