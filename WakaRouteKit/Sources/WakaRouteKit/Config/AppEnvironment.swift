import Foundation

/// Where the app points and who it says it is.
///
/// Production and staging are separated here rather than by a runtime flag so a
/// build cannot be pointed at the wrong backend by accident.
public struct AppEnvironment: Sendable {
    public let manabu2BaseURL: URL
    public let wakarouteBaseURL: URL
    public let clientId: String

    /// The organization owning ワカルート's content.
    ///
    /// Every content read must be scoped to it. `GET /api/v1/paths` otherwise
    /// returns MANABU2's shared catalogue too — 240 corporate AI courses that a
    /// 中学生 must never see next to 数学.
    public let organizationId: String

    /// Keychain service name. Matches the value in the 実装ガイド so a reinstall
    /// of the same bundle finds the credential it wrote last time.
    public let keychainService: String

    public init(
        manabu2BaseURL: URL,
        wakarouteBaseURL: URL,
        clientId: String,
        organizationId: String,
        keychainService: String
    ) {
        self.manabu2BaseURL = manabu2BaseURL
        self.wakarouteBaseURL = wakarouteBaseURL
        self.clientId = clientId
        self.organizationId = organizationId
        self.keychainService = keychainService
    }

    public static let production = AppEnvironment(
        manabu2BaseURL: URL(string: "https://api.manabu2.com")!,
        wakarouteBaseURL: URL(string: "https://wakaroute.com")!,
        clientId: "wakaroute",
        organizationId: "a461577a-3410-4c98-b1d5-db729f3444a1",
        keychainService: "com.wakaroute.app"
    )
}
