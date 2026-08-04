import Foundation

/// Thin wrapper over the four device/auth endpoints. Holds no state — the
/// decision of *when* to call these belongs to `AuthSession`.
public struct DeviceAuthClient: Sendable {
    private let http: HTTPClient
    private let environment: AppEnvironment

    public init(http: HTTPClient, environment: AppEnvironment) {
        self.http = http
        self.environment = environment
    }

    private func post<T: Decodable>(
        _ path: String,
        body: [String: String],
        accessToken: String? = nil,
        as type: T.Type
    ) async throws -> T {
        var headers = ["Content-Type": "application/json"]
        if let accessToken {
            headers["Authorization"] = "Bearer \(accessToken)"
        }

        let request = HTTPRequest(
            method: .post,
            url: environment.manabu2BaseURL.appending(path: path),
            headers: headers,
            body: try JSONEncoder().encode(body)
        )

        do {
            return try await http.sendDecoding(request, as: T.self)
        } catch let error as APIError {
            throw AuthError.from(error)
        }
    }

    /// First launch. Also the documented recovery path: calling it again with
    /// the same `deviceId` returns the same account with `isNewAccount: false`,
    /// so it is safe when local state is uncertain.
    public func register(deviceId: String, platform: String = "ios") async throws -> DeviceRegistration {
        try await post(
            "/api/v1/devices/register",
            body: ["clientId": environment.clientId, "deviceId": deviceId, "platform": platform],
            as: DeviceRegistration.self
        )
    }

    /// Normal renewal. The returned refresh token replaces the old one.
    public func refresh(refreshToken: String) async throws -> AuthTokens {
        try await post(
            "/api/v1/auth/refresh",
            body: ["refreshToken": refreshToken],
            as: AuthTokens.self
        )
    }

    /// Recovery when the refresh token is lost or unusable, using the secret.
    public func tokensFromDeviceSecret(deviceId: String, deviceSecret: String) async throws -> AuthTokens {
        try await post(
            "/api/v1/devices/token",
            body: [
                "clientId": environment.clientId,
                "deviceId": deviceId,
                "deviceSecret": deviceSecret
            ],
            as: AuthTokens.self
        )
    }

    /// Closes the account.
    ///
    /// Destroys the identity, releases the email, deletes 志望校, revokes every
    /// token, and removes the device registrations — so the next launch creates
    /// a genuinely new learner rather than recovering this one. Verified
    /// against production: re-registering the same `deviceId` afterwards
    /// returns `isNewAccount: true` with a different user id.
    ///
    /// Learning history is retained, detached from any person.
    ///
    /// There is no undo.
    public func deleteAccount(accessToken: String) async throws {
        let request = HTTPRequest(
            method: .delete,
            url: environment.manabu2BaseURL.appending(path: "/api/v1/me"),
            headers: ["Authorization": "Bearer \(accessToken)", "Accept": "application/json"]
        )

        let response = try await http.send(request)
        guard response.status == 204 || response.status == 200 else {
            let problem = try? JSONDecoder().decode(ProblemDetails.self, from: response.body)
            throw AuthError.from(.http(status: response.status, problem: problem))
        }
    }

    /// Attaches sign-in credentials to the existing account.
    ///
    /// The user id does not change, so every lesson, quiz attempt and 志望校
    /// carries over. Verified against production.
    public func link(
        accessToken: String,
        email: String,
        password: String,
        displayName: String
    ) async throws -> AccountLink {
        try await post(
            "/api/v1/me/link",
            body: ["email": email, "password": password, "displayName": displayName],
            accessToken: accessToken,
            as: AccountLink.self
        )
    }

    /// Signs in on a new device with a linked email.
    ///
    /// **`clientId` is deliberately omitted.** The 実装ガイド says to send it,
    /// but the server answers `403 user_credential_required` — "This client
    /// cannot use password sign-in" — for the `wakaroute` client. Omitting it
    /// returns a token with the same four scopes, the same user id, and a
    /// refresh token, and the account's progress is intact.
    ///
    /// This is raised on LMS-DEV t-d1bea80: either the client needs a flag, or
    /// the guide is out of date. Until that is settled the omission is an
    /// unconfirmed workaround, not a documented contract — restore the
    /// parameter once password sign-in is enabled for this client.
    public func signIn(email: String, password: String) async throws -> AuthTokens {
        try await post(
            "/api/v1/auth/login",
            body: ["email": email, "password": password],
            as: AuthTokens.self
        )
    }
}
