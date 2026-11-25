import Foundation
import RigModel

/// Owner acts on phone-app credentials. They pass the same gate as Mission Control's writes, so they carry the
/// operator bearer when the daemon has one. There is no route to list credentials: keep the ids you issue.
extension DaemonHTTP {
    /// Issues a credential that answers as `actors`. Its token is returned once; hand it to the phone and drop it.
    /// A daemon without the contract answers 404.
    public func issueAppCredential(
        for actors: [String], appID: String = AppCredential.remoteAppID
    ) async throws(DaemonError) -> AppCredential {
        let body: [String: any Sendable] = [
            "appId": appID, "actors": actors, "job": "human-answer", "attribution": "app-attributed",
        ]
        let data = try? JSONSerialization.data(withJSONObject: body)
        return try await ownerRequest("POST", "/api/apps/v1/credentials", body: data)
    }

    /// Revokes a credential. Idempotent: revoking twice is fine.
    public func revokeAppCredential(id: String) async throws(DaemonError) {
        struct Revoked: Decodable {}
        let _: Revoked = try await ownerRequest("DELETE", "/api/apps/v1/credentials/\(id)", body: nil)
    }

    private func ownerRequest<T: Decodable>(_ method: String, _ path: String, body: Data?) async throws(DaemonError)
        -> T
    {
        var request = URLRequest(url: baseURL.appending(path: path), timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        if let bearer, !bearer.isEmpty { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw .unreachable(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw .http(status: http.statusCode, path: path)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw .decoding(path: path, message: String(describing: error))
        }
    }
}
