import Foundation
import Testing
@testable import WakaRouteKit

/// Records every request and replies from a scripted queue, so tests can assert
/// on exactly which endpoints were called and how often.
final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    struct Stub {
        let status: Int
        let body: Data
    }

    private let lock = NSLock()
    private var responses: [String: [Stub]] = [:]
    private(set) var requestedPaths: [String] = []
    private(set) var sentBodies: [String: [Data]] = [:]
    /// Delay applied to every reply, used to widen the window for races.
    var latency: Duration = .zero

    func stub(path: String, status: Int, json: String) {
        lock.lock(); defer { lock.unlock() }
        responses[path, default: []].append(Stub(status: status, body: Data(json.utf8)))
    }

    func callCount(for path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return requestedPaths.filter { $0 == path }.count
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if latency != .zero { try? await Task.sleep(for: latency) }

        let path = request.url.path()
        let stub = lock.withLock {
            requestedPaths.append(path)
            if let body = request.body { sentBodies[path, default: []].append(body) }
            return responses[path]?.isEmpty == false ? responses[path]!.removeFirst() : nil
        }

        guard let stub else {
            throw APIError.unknown("No stub for \(path)")
        }
        return HTTPResponse(status: stub.status, body: stub.body)
    }
}

private func makeAuthJSON(accessToken: String, refreshToken: String, expiresAt: String) -> String {
    """
    {
      "accessToken": "\(accessToken)",
      "expiresAt": "\(expiresAt)",
      "refreshToken": "\(refreshToken)",
      "scopes": ["read:catalog", "read:progress"],
      "user": { "id": "u-1", "email": "", "displayName": "" }
    }
    """
}

private func makeSession(
    http: StubHTTPClient,
    store: SecretStore = InMemorySecretStore(),
    // Sits between `pastExpiry` and `futureExpiry` so both fixtures mean what
    // their names say.
    now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_000_000_000) }
) -> AuthSession {
    let environment = AppEnvironment.production
    return AuthSession(
        client: DeviceAuthClient(http: http, environment: environment),
        store: store,
        deviceIdProvider: StoredDeviceIdProvider(store: store),
        now: now
    )
}

private let futureExpiry = "2033-01-01T00:00:00Z"
private let pastExpiry = "1971-01-01T00:00:00Z"

@Suite("AuthSession")
struct AuthSessionTests {

    @Test("First launch registers silently and stores the one-time device secret")
    func registersOnFirstLaunch() async throws {
        let http = StubHTTPClient()
        let store = InMemorySecretStore()
        http.stub(path: "/api/v1/devices/register", status: 200, json: """
        {
          "deviceSecret": "mnbd_secret",
          "isNewAccount": true,
          "auth": \(makeAuthJSON(accessToken: "access-1", refreshToken: "refresh-1", expiresAt: futureExpiry))
        }
        """)

        let session = makeSession(http: http, store: store)
        let token = try await session.validAccessToken()

        #expect(token == "access-1")
        #expect(try store.read("deviceSecret") == "mnbd_secret")
        #expect(try store.read("refreshToken") == "refresh-1")
        #expect(http.callCount(for: "/api/v1/devices/register") == 1)
    }

    @Test("A rotated refresh token replaces the stored one")
    func rotatesRefreshToken() async throws {
        let http = StubHTTPClient()
        let store = InMemorySecretStore()
        try store.write("device-id-long-enough", for: "deviceId")
        try store.write("mnbd_secret", for: "deviceSecret")
        try store.write("refresh-1", for: "refreshToken")

        http.stub(path: "/api/v1/auth/refresh", status: 200,
                  json: makeAuthJSON(accessToken: "access-2", refreshToken: "refresh-2", expiresAt: futureExpiry))

        let session = makeSession(http: http, store: store)
        #expect(try await session.validAccessToken() == "access-2")
        #expect(try store.read("refreshToken") == "refresh-2")
    }

    /// The core protection: many callers, exactly one refresh call. Anything
    /// more would replay a single-use token and revoke every session.
    @Test("Concurrent callers trigger only one refresh")
    func concurrentCallersShareOneRefresh() async throws {
        let http = StubHTTPClient()
        http.latency = .milliseconds(50)
        let store = InMemorySecretStore()
        try store.write("device-id-long-enough", for: "deviceId")
        try store.write("refresh-1", for: "refreshToken")

        http.stub(path: "/api/v1/auth/refresh", status: 200,
                  json: makeAuthJSON(accessToken: "access-2", refreshToken: "refresh-2", expiresAt: futureExpiry))

        let session = makeSession(http: http, store: store)

        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<20 {
                group.addTask { try await session.validAccessToken() }
            }
            var collected: [String] = []
            for try await value in group { collected.append(value) }
            return collected
        }

        #expect(tokens.allSatisfy { $0 == "access-2" })
        #expect(http.callCount(for: "/api/v1/auth/refresh") == 1)
    }

    /// A timeout may still have been processed server-side, rotating the token.
    /// Re-sending it is what triggers reuse detection, so we must not.
    @Test("A failed refresh is never retried with the same token")
    func failedRefreshFallsBackToDeviceSecret() async throws {
        let http = StubHTTPClient()
        let store = InMemorySecretStore()
        try store.write("device-id-long-enough", for: "deviceId")
        try store.write("mnbd_secret", for: "deviceSecret")
        try store.write("refresh-1", for: "refreshToken")

        // Refresh fails; recovery via the device secret succeeds.
        http.stub(path: "/api/v1/auth/refresh", status: 500, json: "{}")
        http.stub(path: "/api/v1/devices/token", status: 200,
                  json: makeAuthJSON(accessToken: "access-3", refreshToken: "refresh-3", expiresAt: futureExpiry))

        let session = makeSession(http: http, store: store)
        #expect(try await session.validAccessToken() == "access-3")

        #expect(http.callCount(for: "/api/v1/auth/refresh") == 1)
        #expect(http.callCount(for: "/api/v1/devices/token") == 1)
        #expect(try store.read("refreshToken") == "refresh-3")
    }

    @Test("A rejected device secret re-registers rather than stranding the student")
    func rejectedSecretReRegisters() async throws {
        let http = StubHTTPClient()
        let store = InMemorySecretStore()
        try store.write("device-id-long-enough", for: "deviceId")
        try store.write("stale_secret", for: "deviceSecret")

        http.stub(path: "/api/v1/devices/token", status: 401,
                  json: #"{"status":401,"code":"unauthorized"}"#)
        http.stub(path: "/api/v1/devices/register", status: 200, json: """
        {
          "deviceSecret": "mnbd_new",
          "isNewAccount": false,
          "auth": \(makeAuthJSON(accessToken: "access-4", refreshToken: "refresh-4", expiresAt: futureExpiry))
        }
        """)

        let session = makeSession(http: http, store: store)
        #expect(try await session.validAccessToken() == "access-4")
        #expect(try store.read("deviceSecret") == "mnbd_new")
    }

    @Test("An expired token is renewed before use")
    func renewsExpiredToken() async throws {
        let http = StubHTTPClient()
        let store = InMemorySecretStore()
        try store.write("device-id-long-enough", for: "deviceId")

        http.stub(path: "/api/v1/devices/register", status: 200, json: """
        {
          "deviceSecret": "mnbd_secret",
          "isNewAccount": true,
          "auth": \(makeAuthJSON(accessToken: "stale", refreshToken: "refresh-1", expiresAt: pastExpiry))
        }
        """)
        http.stub(path: "/api/v1/auth/refresh", status: 200,
                  json: makeAuthJSON(accessToken: "fresh", refreshToken: "refresh-2", expiresAt: futureExpiry))

        let session = makeSession(http: http, store: store)
        _ = try await session.registerDevice()

        // The stored token is already past its expiry, so asking for one renews.
        #expect(try await session.validAccessToken() == "fresh")
    }

    @Test("The unconfigured-application 403 surfaces as its own case")
    func missingOwnerOrganisationIsDistinct() async throws {
        let http = StubHTTPClient()
        http.stub(path: "/api/v1/devices/register", status: 403, json: """
        {"status":403,"detail":"This application is not owned by an organization, so it cannot create learners.","code":"admin_required"}
        """)

        let session = makeSession(http: http)

        await #expect(throws: AuthError.applicationNotConfigured) {
            try await session.registerDevice()
        }
    }
}

@Suite("Device identity")
struct DeviceIdentityTests {

    @Test("The device id is generated once and reused")
    func deviceIdIsStable() throws {
        let store = InMemorySecretStore()
        let provider = StoredDeviceIdProvider(store: store)

        let first = try provider.deviceId()
        let second = try provider.deviceId()

        #expect(first == second)
        #expect(first.count >= 16, "The server rejects anything shorter than 16 characters.")
    }

    @Test("A too-short stored value is replaced rather than sent")
    func shortStoredIdIsReplaced() throws {
        let store = InMemorySecretStore()
        try store.write("tooshort", for: "deviceId")

        let generated = try StoredDeviceIdProvider(store: store).deviceId()
        #expect(generated.count >= 16)
    }
}
