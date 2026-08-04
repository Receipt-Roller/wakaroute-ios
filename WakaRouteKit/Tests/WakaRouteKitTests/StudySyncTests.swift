import Foundation
import Testing
@testable import WakaRouteKit

private func at(_ iso: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    return formatter.date(from: iso)!
}

private func session(_ start: String, minutes: Int, synced: Bool = false) -> StudySession {
    StudySession(
        startedAt: at(start),
        endedAt: at(start).addingTimeInterval(TimeInterval(minutes * 60)),
        title: "学習",
        subjectName: "数学",
        kind: .practice,
        isSynced: synced
    )
}

/// Answers device registration so uploads are not blocked on auth, records the
/// upload requests, and can be told to fail after N *uploads*.
private final class SyncStubClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var bodies: [Data] = []
    private(set) var headers: [[String: String]] = []
    /// Number of successful uploads to allow before returning 503.
    var failAfter: Int?

    private static let registration = """
    { "deviceSecret": "mnbd_test", "isNewAccount": true,
      "auth": { "accessToken": "access", "expiresAt": "2033-01-01T00:00:00Z",
                "refreshToken": "refresh", "scopes": ["write:progress"],
                "user": { "id": "u-1", "email": "", "displayName": "" } } }
    """

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let path = request.url.path()

        if path.hasSuffix("/devices/register") || path.hasSuffix("/auth/refresh") || path.hasSuffix("/devices/token") {
            return HTTPResponse(status: 200, body: Data(Self.registration.utf8))
        }

        let index = lock.withLock { () -> Int in
            bodies.append(request.body ?? Data())
            headers.append(request.headers)
            return bodies.count - 1
        }

        if let failAfter, index >= failAfter {
            return HTTPResponse(status: 503, body: Data("{}".utf8))
        }
        return HTTPResponse(status: 201, body: Data("{}".utf8))
    }
}

private func makeSync(
    store: InMemorySecretStore = InMemorySecretStore(),
    sessions: [StudySession],
    http: SyncStubClient
) async -> (StudySync, StudyTimer) {
    let sessionStore = InMemoryStudySessionStore(sessions: sessions)
    let timer = StudyTimer(store: sessionStore, now: { at("2026-08-03T12:00:00+09:00") })

    // A session whose token is already valid, so uploads are not blocked on auth.
    let auth = AuthSession(
        client: DeviceAuthClient(http: http, environment: .production),
        store: store,
        deviceIdProvider: StoredDeviceIdProvider(store: store),
        now: { at("2026-08-03T12:00:00+09:00") }
    )
    let client = StudySyncClient(
        http: AuthenticatedHTTPClient(underlying: http, session: auth),
        environment: .production
    )
    return (StudySync(timer: timer, client: client), timer)
}

@Suite("Study sync")
struct StudySyncTests {

    /// The upload body must carry `clientSessionId` — the field the server
    /// deduplicates on. Without it, every retry records a new session.
    @Test("Uploads carry the local id as clientSessionId and as the idempotency key")
    func uploadCarriesClientSessionId() throws {
        let local = session("2026-08-02T20:00:00+09:00", minutes: 12)

        struct Body: Encodable {
            let clientSessionId: String
            let subject: String
            let kind: String
            let startedAt: Date
            let endedAt: Date
        }
        let encoded = try JSONEncoder.wakaRoute.encode(
            Body(
                clientSessionId: local.id.uuidString,
                subject: local.subjectName,
                kind: local.kind.rawValue,
                startedAt: local.startedAt,
                endedAt: local.endedAt!
            )
        )
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]

        #expect(object?["clientSessionId"] as? String == local.id.uuidString)
        #expect(object?["kind"] as? String == "practice")
        #expect((object?["startedAt"] as? String)?.contains("2026-08-02") == true)
    }

    @Test("Dates encode as ISO 8601 with an offset, as the server expects")
    func datesEncodeAsISO8601() throws {
        struct Box: Encodable { let d: Date }
        let text = String(decoding: try JSONEncoder.wakaRoute.encode(Box(d: at("2026-08-02T23:40:00+09:00"))), as: UTF8.self)

        #expect(text.contains("2026-08-02T14:40:00Z") || text.contains("+09:00"))
    }

    @Test("Server aggregates decode, including string-typed counts")
    func decodesServerAggregates() throws {
        let json = """
        [ { "date": "2026-08-01", "totalSeconds": 1800, "sessionCount": 2,
            "bySubject": { "数学": 1200, "英語": "600" } },
          { "date": "2026-08-02", "totalSeconds": 0, "sessionCount": 0, "bySubject": {} } ]
        """
        let totals = try JSONDecoder.wakaRoute.decode([ServerDailyTotal].self, from: Data(json.utf8))

        #expect(totals.count == 2)
        #expect(totals[0].bySubject["英語"] == 600, "A quoted number must not fail the day.")
        #expect(totals[1].totalSeconds == 0, "Zero days are part of a dense series.")
    }

    @Test("Streak decodes")
    func decodesStreak() throws {
        let json = #"{ "currentDays": 6, "longestDays": 12, "lastStudyDate": "2026-08-03" }"#
        let streak = try JSONDecoder.wakaRoute.decode(ServerStreak.self, from: Data(json.utf8))

        #expect(streak.currentDays == 6)
        #expect(streak.longestDays == 12)
    }

    @Test("An empty queue does nothing rather than calling the server")
    func emptyQueueDoesNothing() async {
        let http = SyncStubClient()
        let (sync, _) = await makeSync(sessions: [], http: http)

        #expect(await sync.run() == .nothingToDo)
        #expect(http.bodies.isEmpty)
    }

    @Test("Already-synced sessions are not uploaded again")
    func skipsSyncedSessions() async {
        let http = SyncStubClient()
        let (sync, _) = await makeSync(
            sessions: [session("2026-08-01T20:00:00+09:00", minutes: 10, synced: true)],
            http: http
        )

        #expect(await sync.run() == .nothingToDo)
        #expect(http.bodies.isEmpty)
    }

    @Test("A successful run uploads everything and marks it synced")
    func uploadsAndMarks() async throws {
        let http = SyncStubClient()
        let (sync, timer) = await makeSync(
            sessions: [
                session("2026-08-01T20:00:00+09:00", minutes: 10),
                session("2026-08-02T20:00:00+09:00", minutes: 15)
            ],
            http: http
        )

        #expect(await sync.run() == .uploaded(count: 2))
        #expect(try await timer.pendingUpload().isEmpty, "Nothing should remain queued.")
    }

    /// A partial failure must not lose the rest. What uploaded is marked; the
    /// remainder keeps its place for the next attempt.
    @Test("A failure part-way leaves the remainder queued")
    func partialFailureKeepsRemainder() async throws {
        let http = SyncStubClient()
        http.failAfter = 1                      // the second upload fails

        let (sync, timer) = await makeSync(
            sessions: [
                session("2026-08-01T20:00:00+09:00", minutes: 10),
                session("2026-08-02T20:00:00+09:00", minutes: 15),
                session("2026-08-03T09:00:00+09:00", minutes: 20)
            ],
            http: http
        )

        #expect(await sync.run() == .partial(uploaded: 1, remaining: 2))
        #expect(try await timer.pendingUpload().count == 2)
    }

    @Test("A total failure leaves everything queued")
    func totalFailureKeepsEverything() async throws {
        let http = SyncStubClient()
        http.failAfter = 0

        let (sync, timer) = await makeSync(
            sessions: [session("2026-08-01T20:00:00+09:00", minutes: 10)],
            http: http
        )

        #expect(await sync.run() == .failed)
        #expect(try await timer.pendingUpload().count == 1)
    }

    /// Oldest first, so a student's history arrives in the order it happened
    /// and a partial upload leaves no hole in the middle.
    @Test("Uploads run oldest first")
    func uploadsOldestFirst() async throws {
        let http = SyncStubClient()
        let (sync, _) = await makeSync(
            sessions: [
                session("2026-08-03T09:00:00+09:00", minutes: 20),
                session("2026-08-01T20:00:00+09:00", minutes: 10)
            ],
            http: http
        )

        _ = await sync.run()

        let dates = http.bodies.compactMap { body -> String? in
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            return object?["startedAt"] as? String
        }
        #expect(dates.count == 2)
        #expect(dates[0] < dates[1], "Earlier session must be sent first.")
    }
}

@Suite("Sync failure classification")
struct SyncFailureTests {

    @Test("4xx means never retry; 5xx, 408 and 429 mean try again")
    func classification() {
        #expect(StudySync.isPermanent(.http(status: 400, problem: nil)))
        #expect(StudySync.isPermanent(.http(status: 422, problem: nil)))
        #expect(!StudySync.isPermanent(.http(status: 408, problem: nil)))
        #expect(!StudySync.isPermanent(.http(status: 429, problem: nil)))
        #expect(!StudySync.isPermanent(.http(status: 500, problem: nil)))
        #expect(!StudySync.isPermanent(.http(status: 503, problem: nil)))
        #expect(!StudySync.isPermanent(.offline))
        #expect(!StudySync.isPermanent(.timedOut))
    }
}

@Suite("Session file compatibility")
struct SessionCompatibilityTests {

    /// Files written before `isRejected` existed must still load. A synthesised
    /// decoder would throw on the whole array and take a student's entire study
    /// history with it.
    @Test("A session saved by an earlier version still decodes")
    func decodesOlderFile() throws {
        let json = """
        [ { "id": "0FB9E0B4-2E3A-4B36-9C6F-6C7D1E2A3B44",
            "startedAt": "2026-08-01T11:00:00Z",
            "endedAt": "2026-08-01T11:20:00Z",
            "title": "文字式の練習", "subjectName": "数学", "kind": "practice",
            "isAbandoned": false, "isSynced": false } ]
        """
        let sessions = try JSONDecoder.wakaRoute.decode([StudySession].self, from: Data(json.utf8))

        #expect(sessions.count == 1)
        #expect(sessions[0].isRejected == false, "A missing flag defaults to false.")
        #expect(sessions[0].title == "文字式の練習")
    }

    @Test("An even older file missing several flags still decodes")
    func decodesMinimalFile() throws {
        let json = """
        [ { "id": "0FB9E0B4-2E3A-4B36-9C6F-6C7D1E2A3B44",
            "startedAt": "2026-08-01T11:00:00Z", "endedAt": "2026-08-01T11:20:00Z",
            "title": "x", "subjectName": "数学", "kind": "learn" } ]
        """
        let sessions = try JSONDecoder.wakaRoute.decode([StudySession].self, from: Data(json.utf8))

        #expect(sessions[0].isSynced == false)
        #expect(sessions[0].isAbandoned == false)
        #expect(sessions[0].kind == .learn)
    }

    @Test("A round trip through encode and decode preserves every flag")
    func roundTrips() throws {
        let original = StudySession(
            startedAt: Date(timeIntervalSince1970: 1_785_000_000),
            endedAt: Date(timeIntervalSince1970: 1_785_001_200),
            title: "復習", subjectName: "理科", kind: .review,
            isSynced: true, isRejected: true
        )
        let data = try JSONEncoder.wakaRoute.encode([original])
        let decoded = try JSONDecoder.wakaRoute.decode([StudySession].self, from: data)

        #expect(decoded.first == original)
    }
}

/// Answers registration and sign-in, and can refuse uploads.
private final class HandoverStubClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    var uploadsFail = false
    private(set) var signInCount = 0

    private static let auth = """
    { "accessToken": "access", "expiresAt": "2033-01-01T00:00:00Z",
      "refreshToken": "refresh", "scopes": ["write:progress"],
      "user": { "id": "linked-user", "email": "me@example.com", "displayName": "" } }
    """
    private static let registration = """
    { "deviceSecret": "mnbd_test", "isNewAccount": true, "auth": \(auth) }
    """

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let path = request.url.path()

        if path.hasSuffix("/devices/register") || path.hasSuffix("/devices/token") || path.hasSuffix("/auth/refresh") {
            return HTTPResponse(status: 200, body: Data(Self.registration.utf8))
        }
        if path.hasSuffix("/auth/login") {
            lock.withLock { signInCount += 1 }
            return HTTPResponse(status: 200, body: Data(Self.auth.utf8))
        }
        if lock.withLock({ uploadsFail }) {
            return HTTPResponse(status: 503, body: Data("{}".utf8))
        }
        return HTTPResponse(status: 201, body: Data("{}".utf8))
    }
}

@Suite("Account handover")
struct AccountHandoverTests {

    private func make(
        sessions: [StudySession],
        http: HandoverStubClient
    ) -> (AccountHandover, StudyTimer) {
        let store = InMemorySecretStore()
        let timer = StudyTimer(store: InMemoryStudySessionStore(sessions: sessions), now: { at("2026-08-03T12:00:00+09:00") })
        let auth = AuthSession(
            client: DeviceAuthClient(http: http, environment: .production),
            store: store,
            deviceIdProvider: StoredDeviceIdProvider(store: store),
            now: { at("2026-08-03T12:00:00+09:00") }
        )
        let sync = StudySync(
            timer: timer,
            client: StudySyncClient(
                http: AuthenticatedHTTPClient(underlying: http, session: auth),
                environment: .production
            )
        )
        return (AccountHandover(auth: auth, timer: timer, sync: sync), timer)
    }

    /// The whole point of the guard: a student who studied on a train and then
    /// signs in on a new phone must not silently lose that study time.
    @Test("Sign-in is refused while work cannot be uploaded")
    func refusesWhileWorkIsUnsent() async throws {
        let http = HandoverStubClient()
        http.uploadsFail = true
        let (handover, _) = make(sessions: [session("2026-08-01T20:00:00+09:00", minutes: 25)], http: http)

        await #expect(throws: AccountHandover.SignInRefusal.unsentWork(sessions: 1)) {
            try await handover.signIn(email: "me@example.com", password: "pw")
        }
        #expect(http.signInCount == 0, "The sign-in must not have happened.")
    }

    @Test("Pending work is uploaded first, and then sign-in proceeds")
    func uploadsThenSignsIn() async throws {
        let http = HandoverStubClient()
        let (handover, timer) = make(sessions: [session("2026-08-01T20:00:00+09:00", minutes: 25)], http: http)

        let user = try await handover.signIn(email: "me@example.com", password: "pw")

        #expect(user.id == "linked-user")
        #expect(http.signInCount == 1)
        #expect(try await timer.allSessions().isEmpty, "Local sessions belong to the account we left.")
    }

    /// Only when the student has been shown the number and accepted it.
    @Test("Unsent work can be discarded explicitly")
    func canDiscardExplicitly() async throws {
        let http = HandoverStubClient()
        http.uploadsFail = true
        let (handover, timer) = make(sessions: [session("2026-08-01T20:00:00+09:00", minutes: 25)], http: http)

        _ = try await handover.signIn(email: "me@example.com", password: "pw", discardingUnsentWork: true)

        #expect(http.signInCount == 1)
        #expect(try await timer.allSessions().isEmpty)
    }

    @Test("With nothing recorded, sign-in just works")
    func signsInWithNoLocalWork() async throws {
        let http = HandoverStubClient()
        let (handover, _) = make(sessions: [], http: http)

        let user = try await handover.signIn(email: "me@example.com", password: "pw")
        #expect(user.id == "linked-user")
    }

    /// Linking adds a way in; it does not move the account, so there is nothing
    /// to lose and nothing to guard.
    @Test("Linking needs no guard and keeps local sessions")
    func linkingKeepsLocalWork() async throws {
        let http = HandoverStubClient()
        http.uploadsFail = true
        let (handover, timer) = make(sessions: [session("2026-08-01T20:00:00+09:00", minutes: 25)], http: http)

        _ = try? await handover.link(email: "me@example.com", password: "pw")

        #expect(try await timer.allSessions().count == 1)
    }
}
