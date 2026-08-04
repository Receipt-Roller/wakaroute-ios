import Foundation

public struct AuthenticatedUser: Decodable, Sendable, Equatable {
    public let id: String
    public let email: String
    public let displayName: String

    /// An account that has not been linked yet has no email. The guide is
    /// explicit that this is the desired default for a minor, not a gap.
    public var isLinked: Bool { !email.isEmpty }
}

public struct AuthTokens: Decodable, Sendable, Equatable {
    public let accessToken: String
    public let expiresAt: Date
    public let refreshToken: String
    public let scopes: [String]
    public let user: AuthenticatedUser

    /// Treats a token as expired slightly early so a request does not leave
    /// with a credential that dies in flight.
    public func isFresh(at now: Date, leeway: TimeInterval = 60) -> Bool {
        now.addingTimeInterval(leeway) < expiresAt
    }
}

/// The result of attaching an email to an existing account.
public struct AccountLink: Decodable, Sendable, Equatable {
    public let userId: String
    public let email: String
    public let message: String?
}

public struct DeviceRegistration: Decodable, Sendable {
    /// Returned exactly once, at registration. If it is not persisted before
    /// anything else happens, it is gone.
    public let deviceSecret: String
    public let isNewAccount: Bool
    public let auth: AuthTokens
}

public enum AuthError: Error, Sendable, Equatable {
    /// `wakaroute-app` has no owning organization set in the MANABU2 console.
    /// Registration cannot succeed for any user until that is configured.
    case applicationNotConfigured
    /// Too many registrations from this IP. Wait `retryAfter` seconds.
    case rateLimited(retryAfter: TimeInterval?)
    /// Device secret rejected — the account must be recovered by re-registering.
    case deviceRejected
    /// This account already has an email attached.
    case alreadyLinked
    /// That email belongs to another account; offer sign-in instead.
    case emailInUse
    case api(APIError)

    /// Maps the documented `code` values onto cases the UI can act on.
    static func from(_ error: APIError) -> AuthError {
        guard case let .http(status, problem) = error else { return .api(error) }

        switch (status, problem?.code) {
        case (403, "admin_required"):
            return .applicationNotConfigured
        case (429, _):
            return .rateLimited(retryAfter: nil)
        case (401, _):
            return .deviceRejected
        case (409, "already_linked"):
            return .alreadyLinked
        case (409, _):
            return .emailInUse
        default:
            return .api(error)
        }
    }
}
