import Foundation
import Testing
@testable import WakaRouteKit

@Suite("Version ordering")
struct AppVersionTests {

    /// The first bug every hand-rolled version check has.
    @Test("Ten sorts after nine, unlike string comparison")
    func numericNotLexical() {
        #expect(AppVersion("1.9.0") < AppVersion("1.10.0"))
        #expect(!(AppVersion("1.10.0") < AppVersion("1.9.0")))
        #expect("1.10.0" < "1.9.0", "Which is exactly why AppVersion exists.")
    }

    @Test("Missing components count as zero")
    func missingComponents() {
        #expect(AppVersion("1.2") == AppVersion("1.2.0"))
        #expect(AppVersion("1.2") < AppVersion("1.2.1"))
        #expect(AppVersion("2") > AppVersion("1.9.9"))
    }

    @Test("A build suffix does not make a version newer")
    func buildSuffix() {
        #expect(AppVersion("1.2.0-beta.3") == AppVersion("1.2.0.3"))
        #expect(AppVersion("1.2.0") < AppVersion("1.2.1"))
    }

    @Test("A version string with no digits is not usable")
    func unusable() {
        #expect(AppVersion("—").isUsable == false)
        #expect(AppVersion("1.0.0").isUsable)
    }
}

/// Every one of these is a way the gate could lock a student out of their own
/// revision. The rule is one sentence: **stop only when told to, in writing.**
@Suite("The update gate fails open")
struct AppVersionGateTests {

    @Test("Below the minimum is the one case that stops the app")
    func belowMinimumStops() {
        let decision = AppVersionGate.decide(
            current: "1.0.0",
            requirement: VersionRequirement(minimumVersion: "1.1.0", storeUrl: "https://apps.apple.com/jp/app/id1")
        )

        guard case let .required(_, storeUrl) = decision else {
            Issue.record("Expected the app to stop, got \(decision)")
            return
        }
        #expect(storeUrl?.host() == "apps.apple.com")
    }

    @Test("At the minimum is allowed — the boundary is not an off-by-one")
    func atMinimumIsAllowed() {
        #expect(AppVersionGate.decide(
            current: "1.1.0",
            requirement: VersionRequirement(minimumVersion: "1.1.0")
        ) == .allowed)
    }

    @Test("Behind the latest but at the minimum is only a suggestion")
    func behindLatestIsOptional() {
        let decision = AppVersionGate.decide(
            current: "1.1.0",
            requirement: VersionRequirement(minimumVersion: "1.0.0", latestVersion: "1.2.0", message: "新しい問題を追加しました。")
        )

        guard case let .optional(message, _) = decision else {
            Issue.record("Expected a suggestion, got \(decision)")
            return
        }
        #expect(message == "新しい問題を追加しました。")
    }

    @Test("No minimum stated means nothing is blocked")
    func noMinimum() {
        #expect(AppVersionGate.decide(
            current: "0.1.0",
            requirement: VersionRequirement(latestVersion: "9.9.9")
        ) != .required(message: nil, storeUrl: nil))
    }

    /// A typo in the published JSON must not become a lockout.
    @Test("An unreadable minimum is ignored rather than treated as newer")
    func unreadableMinimum() {
        #expect(AppVersionGate.decide(
            current: "1.0.0",
            requirement: VersionRequirement(minimumVersion: "coming soon")
        ) == .allowed)
    }

    @Test("A build with no readable version of its own is never blocked")
    func unreadableCurrentVersion() {
        #expect(AppVersionGate.decide(
            current: "—",
            requirement: VersionRequirement(minimumVersion: "99.0.0")
        ) == .allowed)
    }

    @Test("An empty document blocks nothing")
    func emptyDocument() throws {
        let requirement = try JSONDecoder().decode(VersionRequirement.self, from: Data("{}".utf8))
        #expect(AppVersionGate.decide(current: "1.0.0", requirement: requirement) == .allowed)
    }

    /// The one that matters most: if the endpoint is down, every student is
    /// still allowed in. Blocking here would take the whole service offline for
    /// people whose app is perfectly current.
    @Test("An unreachable endpoint lets everyone through")
    func unreachableEndpointAllows() async {
        struct DeadClient: HTTPClient {
            func send(_ request: HTTPRequest) async throws -> HTTPResponse {
                throw APIError.offline
            }
        }

        let gate = AppVersionGate(http: DeadClient(), environment: .production)
        #expect(await gate.decision(for: "0.0.1") == .allowed)
    }

    @Test("A 500, or HTML where JSON was expected, lets everyone through")
    func badResponsesAllow() async {
        struct OddClient: HTTPClient {
            let status: Int
            let body: String
            func send(_ request: HTTPRequest) async throws -> HTTPResponse {
                HTTPResponse(status: status, body: Data(body.utf8))
            }
        }

        for client in [
            OddClient(status: 500, body: "{}"),
            OddClient(status: 200, body: "<!doctype html><html>oops</html>"),
            OddClient(status: 404, body: "")
        ] {
            let gate = AppVersionGate(http: client, environment: .production)
            #expect(await gate.decision(for: "0.0.1") == .allowed)
        }
    }

    @Test("The real published shape decodes")
    func decodesPublishedShape() throws {
        let json = """
        { "minimumVersion": "1.0.0", "latestVersion": "1.1.0",
          "message": "新しい問題を追加しました。",
          "storeUrl": "https://apps.apple.com/jp/app/id0000000000" }
        """
        let requirement = try JSONDecoder().decode(VersionRequirement.self, from: Data(json.utf8))

        #expect(requirement.minimumVersion == "1.0.0")
        #expect(AppVersionGate.decide(current: "0.9.0", requirement: requirement) != .allowed)
    }
}
