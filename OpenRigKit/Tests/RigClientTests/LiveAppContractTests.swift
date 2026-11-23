import Foundation
import RigModel
import Testing

@testable import RigClient

/// The phone-app contract on the real daemon. Opt-in only, with the person's yes: it issues an app credential for
/// OPENRIG_APP_ACTOR, reads, answers nothing, and revokes the credential before finishing.
/// Run: OPENRIG_LIVE_APP=1 OPENRIG_APP_ACTOR=<person>@external swift test --filter LiveAppContractTests
@Suite(
    .serialized,
    .enabled("set OPENRIG_LIVE_APP=1 and OPENRIG_APP_ACTOR=<person>@external") {
        let env = ProcessInfo.processInfo.environment
        return env["OPENRIG_LIVE_APP"] == "1" && env["OPENRIG_APP_ACTOR"]?.isEmpty == false
    })
struct LiveAppContractTests {
    let env = ProcessInfo.processInfo.environment

    @Test(.timeLimit(.minutes(1))) func issueReadRevokeThenRefused() async throws {
        let actor = try #require(env["OPENRIG_APP_ACTOR"])
        let base = DaemonLocator().locate().baseURL
        let owner = DaemonHTTP(baseURL: base, bearer: env["OPENRIG_AUTH_BEARER_TOKEN"])
        let credential = try await owner.issueAppCredential(for: [actor])
        let app = AppClient(baseURL: base, token: credential.token, actor: actor)

        var readError: (any Error)?
        do {
            let capabilities = try await app.capabilities()
            #expect(capabilities.supportsAnswering)
            #expect(capabilities.actors == [actor])
            let needs = try await app.needsMe()
            #expect(!needs.sources.isEmpty)
            if let first = needs.requests.first {
                #expect(try await app.request(id: first.id).id == first.id)
            }
        } catch {
            readError = error
        }
        // Always revoke, even when a read failed.
        try await owner.revokeAppCredential(id: credential.id)
        if let readError { throw readError }

        await #expect(throws: AppError.unpaired) { try await app.needsMe() }
    }
}
