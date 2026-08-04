import Foundation

/// A `CFBundleShortVersionString`, compared the way versions actually order.
///
/// String comparison gets this wrong the first time a minor version reaches
/// ten: `"1.10.0" < "1.9.0"` is true as text and false as a version. Getting it
/// wrong here would lock every student out of a build that is perfectly current.
public struct AppVersion: Comparable, Sendable, Equatable, CustomStringConvertible {
    private let components: [Int]
    public let description: String

    /// Non-numeric parts are dropped rather than guessed at, so `1.2.0-beta.3`
    /// compares as `1.2.0`. A build with no digits at all yields `0`, which is
    /// below every published minimum — see `AppVersionGate` for why that still
    /// does not lock anyone out.
    public init(_ text: String) {
        description = text
        components = text
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    var isUsable: Bool { !components.isEmpty }
}

/// What the server says about which versions may still run.
public struct VersionRequirement: Decodable, Sendable, Equatable {
    /// Below this, the app stops. Absent means nothing is blocked.
    public let minimumVersion: String?
    /// Below this, the app mentions an update but carries on.
    public let latestVersion: String?
    public let message: String?
    public let storeUrl: String?

    private enum CodingKeys: String, CodingKey {
        case minimumVersion, latestVersion, message, storeUrl
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        minimumVersion = try c.decodeIfPresent(String.self, forKey: .minimumVersion)
        latestVersion = try c.decodeIfPresent(String.self, forKey: .latestVersion)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        storeUrl = try c.decodeIfPresent(String.self, forKey: .storeUrl)
    }

    public init(minimumVersion: String? = nil, latestVersion: String? = nil, message: String? = nil, storeUrl: String? = nil) {
        self.minimumVersion = minimumVersion
        self.latestVersion = latestVersion
        self.message = message
        self.storeUrl = storeUrl
    }
}

public enum UpdateDecision: Sendable, Equatable {
    case allowed
    /// Worth updating, but the student can carry on.
    case optional(message: String?, storeUrl: URL?)
    /// The app must not be used until it is updated.
    case required(message: String?, storeUrl: URL?)
}

/// Decides whether this build may still run.
///
/// **The default is always to let the student in.** A forced update is a
/// feature that locks children out of their revision, and every way this can go
/// wrong — the endpoint down, a typo in the JSON, a train tunnel — would lock
/// out *everyone at once*, including the ones who are already up to date. So the
/// app stops only when the server explicitly and legibly says to stop, and any
/// doubt resolves to `allowed`.
public struct AppVersionGate: Sendable {
    private let http: any HTTPClient
    private let environment: AppEnvironment

    public init(http: any HTTPClient, environment: AppEnvironment) {
        self.http = http
        self.environment = environment
    }

    public func decision(for currentVersion: String) async -> UpdateDecision {
        guard let requirement = await fetch() else { return .allowed }
        return Self.decide(current: currentVersion, requirement: requirement)
    }

    /// Pure, so every fail-open path is testable without a network.
    public static func decide(current currentVersion: String, requirement: VersionRequirement) -> UpdateDecision {
        let current = AppVersion(currentVersion)
        // A build whose version string carries no digits cannot be compared, and
        // guessing would block it. Nothing is enforced against it.
        guard current.isUsable else { return .allowed }

        let store = requirement.storeUrl.flatMap(URL.init(string:))

        if let minimum = requirement.minimumVersion.map(AppVersion.init), minimum.isUsable, current < minimum {
            return .required(message: requirement.message, storeUrl: store)
        }
        if let latest = requirement.latestVersion.map(AppVersion.init), latest.isUsable, current < latest {
            return .optional(message: requirement.message, storeUrl: store)
        }
        return .allowed
    }

    private func fetch() async -> VersionRequirement? {
        var components = URLComponents(
            url: environment.wakarouteBaseURL.appending(path: "/api/app-version"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "platform", value: "ios")]
        guard let url = components?.url else { return nil }

        let request = HTTPRequest(method: .get, url: url, headers: ["Accept": "application/json"])
        guard
            let response = try? await http.send(request),
            (200..<300).contains(response.status),
            let requirement = try? JSONDecoder().decode(VersionRequirement.self, from: response.body)
        else {
            // Unreachable, refused, or unreadable. Nothing here is evidence that
            // this build is too old — only that we could not ask.
            return nil
        }
        return requirement
    }
}
