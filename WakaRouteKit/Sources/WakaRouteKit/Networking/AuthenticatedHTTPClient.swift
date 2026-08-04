import Foundation

/// Attaches the learner's token to every request, and renews once if the
/// server says it has expired.
///
/// The single retry is deliberate. `AuthSession` serialises renewal and never
/// reuses a refresh token, so one retry either succeeds with a fresh token or
/// reveals a genuine authorisation problem. Retrying further would just hammer
/// the endpoint that already said no.
public struct AuthenticatedHTTPClient: HTTPClient {
    private let underlying: any HTTPClient
    private let session: AuthSession

    public init(underlying: any HTTPClient, session: AuthSession) {
        self.underlying = underlying
        self.session = session
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var authorised = request
        authorised.headers["Authorization"] = "Bearer \(try await session.validAccessToken())"

        let response = try await underlying.send(authorised)
        guard response.status == 401 else { return response }

        // The token was rejected. Force a renewal and try exactly once more.
        await session.invalidateAccessToken()
        var retried = request
        retried.headers["Authorization"] = "Bearer \(try await session.validAccessToken())"
        return try await underlying.send(retried)
    }
}

extension AuthSession {
    /// Drops the in-memory token so the next request renews.
    ///
    /// Does not touch the refresh token or the device secret — this is "the
    /// access token went stale", not "this device is no longer trusted".
    public func invalidateAccessToken() {
        forgetAccessToken()
    }
}
