import Foundation

/// A day's study as the server records it.
public struct ServerDailyTotal: Decodable, Sendable, Equatable {
    /// `yyyy-MM-dd`, in the server's calendar.
    public let date: String
    public let totalSeconds: Int
    public let sessionCount: Int
    public let bySubject: [String: Int]

    private enum CodingKeys: String, CodingKey { case date, totalSeconds, sessionCount, bySubject }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(String.self, forKey: .date)
        totalSeconds = try c.decodeIfPresent(FlexibleInt.self, forKey: .totalSeconds)?.value ?? 0
        sessionCount = try c.decodeIfPresent(FlexibleInt.self, forKey: .sessionCount)?.value ?? 0
        bySubject = (try c.decodeIfPresent([String: FlexibleInt].self, forKey: .bySubject) ?? [:])
            .mapValues(\.value)
    }
}

public struct ServerStreak: Decodable, Sendable, Equatable {
    public let currentDays: Int
    public let longestDays: Int
    public let lastStudyDate: String?

    private enum CodingKeys: String, CodingKey { case currentDays, longestDays, lastStudyDate }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        currentDays = try c.decodeIfPresent(FlexibleInt.self, forKey: .currentDays)?.value ?? 0
        longestDays = try c.decodeIfPresent(FlexibleInt.self, forKey: .longestDays)?.value ?? 0
        lastStudyDate = try c.decodeIfPresent(String.self, forKey: .lastStudyDate)
    }
}

/// Uploads finished study sessions and reads back the server's aggregates.
public struct StudySyncClient: Sendable {
    private let http: any HTTPClient
    private let environment: AppEnvironment

    public init(http: AuthenticatedHTTPClient, environment: AppEnvironment) {
        self.http = http
        self.environment = environment
    }

    /// Records one finished session.
    ///
    /// `clientSessionId` is the local session's UUID and is what the server
    /// deduplicates on — verified against production: re-sending the same
    /// `clientSessionId`, even under a different `Idempotency-Key`, returns the
    /// original `sessionId` and does not create a second record.
    ///
    /// The `Idempotency-Key` is derived from that same id rather than generated
    /// fresh, so a retry is byte-identical to the attempt it replaces.
    public func upload(_ session: StudySession) async throws {
        struct Body: Encodable {
            let clientSessionId: String
            let subject: String
            let kind: String
            let startedAt: Date
            let endedAt: Date
        }

        guard let endedAt = session.endedAt else { return }

        let body = Body(
            clientSessionId: session.id.uuidString,
            subject: session.subjectName,
            kind: session.kind.rawValue,
            startedAt: session.startedAt,
            endedAt: endedAt
        )

        let request = HTTPRequest(
            method: .post,
            url: environment.manabu2BaseURL.appending(path: "/api/v1/me/study-sessions"),
            headers: [
                "Content-Type": "application/json",
                "Accept": "application/json",
                "Idempotency-Key": session.id.uuidString
            ],
            body: try JSONEncoder.wakaRoute.encode(body)
        )

        let response = try await http.send(request)
        guard (200..<300).contains(response.status) else {
            let problem = try? JSONDecoder().decode(ProblemDetails.self, from: response.body)
            throw APIError.http(status: response.status, problem: problem)
        }
    }

    public func summary(from: String, to: String) async throws -> [ServerDailyTotal] {
        var components = URLComponents(
            url: environment.manabu2BaseURL.appending(path: "/api/v1/me/study-summary"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "from", value: from),
            URLQueryItem(name: "to", value: to),
            URLQueryItem(name: "granularity", value: "day")
        ]
        guard let url = components?.url else { throw APIError.unknown("Could not build the summary URL.") }

        return try await http.sendDecoding(
            HTTPRequest(method: .get, url: url, headers: ["Accept": "application/json"]),
            as: [ServerDailyTotal].self
        )
    }

    public func streak() async throws -> ServerStreak {
        try await http.sendDecoding(
            HTTPRequest(
                method: .get,
                url: environment.manabu2BaseURL.appending(path: "/api/v1/me/study-streak"),
                headers: ["Accept": "application/json"]
            ),
            as: ServerStreak.self
        )
    }
}

extension JSONEncoder {
    static let wakaRoute: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

/// Drains the local queue to the server.
///
/// Separate from `StudyTimer` so recording never depends on the network:
/// sessions are written locally first and uploaded whenever this runs.
public actor StudySync {
    public enum Outcome: Sendable, Equatable {
        case nothingToDo
        case uploaded(count: Int)
        /// Some uploads failed; the rest stay queued for next time.
        case partial(uploaded: Int, remaining: Int)
        case failed
    }

    private let timer: StudyTimer
    private let client: StudySyncClient
    private var isRunning = false

    public init(timer: StudyTimer, client: StudySyncClient) {
        self.timer = timer
        self.client = client
    }

    /// Uploads everything queued, oldest first.
    ///
    /// Order matters: a student's history should arrive in the order it
    /// happened, and stopping at the first failure keeps it that way rather
    /// than leaving a hole in the middle.
    @discardableResult
    public func run() async -> Outcome {
        guard !isRunning else { return .nothingToDo }
        isRunning = true
        defer { isRunning = false }

        guard let pending = try? await timer.pendingUpload(), !pending.isEmpty else {
            return .nothingToDo
        }

        var uploaded: Set<UUID> = []
        var rejected: Set<UUID> = []

        for session in pending {
            do {
                try await client.upload(session)
                uploaded.insert(session.id)
            } catch let error as APIError where Self.isPermanent(error) {
                // The server will refuse this one every time — a timestamp in
                // the future from a device with a wrong clock, for instance.
                // Retrying forever would leave it at the head of the queue and
                // block every later session behind it. Set it aside and carry
                // on with the rest.
                rejected.insert(session.id)
            } catch {
                // Transient. Stop here so the remainder keeps its order, and
                // try again next time.
                break
            }
        }

        if !uploaded.isEmpty { try? await timer.markSynced(ids: uploaded) }
        if !rejected.isEmpty { try? await timer.markRejected(ids: rejected) }

        let handled = uploaded.count + rejected.count
        let remaining = pending.count - handled

        if uploaded.isEmpty && rejected.isEmpty { return .failed }
        return remaining == 0
            ? .uploaded(count: uploaded.count)
            : .partial(uploaded: uploaded.count, remaining: remaining)
    }

    /// Whether the server's answer means "never send this again".
    ///
    /// A `4xx` is the client's fault and will not fix itself — except `408` and
    /// `429`, which are about timing rather than the request.
    static func isPermanent(_ error: APIError) -> Bool {
        guard case let .http(status, _) = error else { return false }
        return (400..<500).contains(status) && status != 408 && status != 429
    }
}
