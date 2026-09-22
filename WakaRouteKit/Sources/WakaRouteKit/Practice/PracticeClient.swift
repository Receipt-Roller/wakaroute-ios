import Foundation

/// How a session picks its questions.
public enum PracticeMode: String, Sendable, Encodable {
    /// Follows the answers: drops to a prerequisite when the student struggles.
    case adaptive
    /// A fixed list, in order.
    case fixed
    /// The 理解要素 whose re-check has come due. Takes no concept codes.
    case review
}

/// What to report, and about what.
public struct ContentReport: Sendable, Equatable, Encodable {
    public struct Target: Sendable, Equatable {
        public let kind: String
        /// The hint tier, the analysis id — whatever identifies the thing.
        public let id: String?
    }

    public let itemId: String
    public let targetKind: String
    public let targetId: String?
    public let reason: String
    public let text: String?

    /// `inappropriate`, `wrong`, `leak`, `confusing`, `other`.
    public init(itemId: String, targetKind: String, targetId: String? = nil, reason: String, text: String? = nil) {
        self.itemId = itemId
        self.targetKind = targetKind
        self.targetId = targetId
        self.reason = reason
        self.text = text
    }
}

/// Why a session could not start or continue, in terms a screen can act on.
public enum PracticeRefusal: Sendable, Equatable {
    /// Nothing to ask. In `review` mode this is the good news — nothing is due.
    /// Anywhere else it means the organisation has no published questions for
    /// these 理解要素.
    case noQuestions
    /// The session is over; it cannot take another answer.
    case sessionNotActive
    /// Answered a different question from the one on screen. Always a bug here,
    /// never something the student did.
    case wrongItem
    /// The hint ladder is used up.
    case noMoreHints
    /// Started with hints off.
    case hintsOff
    case invalidRequest
    /// Called with an API key rather than the learner's own token.
    case learnerTokenRequired

    public init?(_ error: any Error) {
        switch (error as? APIError)?.code {
        case "no_questions": self = .noQuestions
        case "session_not_active": self = .sessionNotActive
        case "wrong_item": self = .wrongItem
        case "no_more_hints": self = .noMoreHints
        case "hints_off": self = .hintsOff
        case "invalid_request": self = .invalidRequest
        case "user_credential_required": self = .learnerTokenRequired
        default: return nil
        }
    }
}

/// MANABU2's adaptive practice, as the student's own sessions.
///
/// **Nothing here marks an answer.** The question arrives without its answer,
/// the answer goes to the server, and the verdict comes back — start guide §6.1.
/// A client that could mark would be a client that could be made to lie, and a
/// student who found the answer in the app would have found it instead of the
/// method.
public struct PracticeClient: Sendable {
    private let http: any HTTPClient
    private let environment: AppEnvironment

    public init(http: AuthenticatedHTTPClient, environment: AppEnvironment) {
        self.http = http
        self.environment = environment
    }

    /// Every call here is organisation-scoped, and a learner who is not a
    /// member of it gets 404. It comes from the environment for the same reason
    /// content reads do — see `AppEnvironment.organizationId`.
    private var organizationId: String { environment.organizationId }

    // MARK: Starting

    /// Opens a session and returns it with its first question.
    ///
    /// `clientReference` is sent on every start and kept stable by the caller:
    /// a start that times out and is retried resumes the session the server
    /// already opened, instead of stranding it and beginning a second.
    public func start(
        mode: PracticeMode = .adaptive,
        conceptCodes: [String] = [],
        questionIds: [String] = [],
        questionLimit: Int = 10,
        timeLimitSeconds: Int? = nil,
        allowHints: Bool = true,
        maxAttempts: Int = 3,
        clientReference: String,
        purpose: String = "practice"
    ) async throws -> PracticeSession {
        struct Body: Encodable {
            let organizationId: String
            let mode: PracticeMode
            let conceptCodes: [String]?
            let questionIds: [String]?
            let questionLimit: Int
            let timeLimitSeconds: Int?
            let allowHints: Bool
            let maxAttempts: Int
            let clientReference: String
            let purpose: String
        }

        // `seed` is deliberately not sent. The server picks it, and letting the
        // client choose would let it choose the question.
        let body = Body(
            organizationId: organizationId,
            mode: mode,
            conceptCodes: mode == .adaptive && !conceptCodes.isEmpty ? conceptCodes : nil,
            questionIds: mode == .fixed && !questionIds.isEmpty ? questionIds : nil,
            questionLimit: questionLimit,
            timeLimitSeconds: timeLimitSeconds,
            allowHints: allowHints,
            maxAttempts: maxAttempts,
            clientReference: clientReference,
            purpose: purpose
        )

        return try await send(.post, "", body: body, as: PracticeSession.self)
    }

    // MARK: During

    /// Submits an answer and returns the verdict with the session's next state.
    ///
    /// `timeMs` is measured from the question appearing, by the caller — the
    /// server cannot see when it was drawn, and both the analysis and the
    /// mastery model use it.
    public func answer(
        sessionId: String,
        itemId: String,
        answer: PracticeAnswer,
        timeMs: Int
    ) async throws -> AnswerResult {
        struct Body: Encodable {
            let itemId: String
            let answer: PracticeAnswer
            let timeMs: Int
        }

        return try await send(
            .post, "/\(sessionId)/answer",
            body: Body(itemId: itemId, answer: answer, timeMs: timeMs),
            as: AnswerResult.self
        )
    }

    /// Climbs one rung of the hint ladder.
    ///
    /// One call, one rung, in a fixed order that cannot be skipped. That is the
    /// server's rule and it is the right one: the point is to get the student
    /// to the answer themselves, and a ladder you can jump to the top of is a
    /// button marked 答え.
    public func hint(sessionId: String, itemId: String) async throws -> PracticeHint {
        struct Body: Encodable { let itemId: String }
        return try await send(.post, "/\(sessionId)/hint", body: Body(itemId: itemId), as: PracticeHint.self)
    }

    /// Shows the answer, because the student asked.
    ///
    /// Closes the question as `revealed`, which does not count as understanding
    /// it. Offered after the hints, never instead of them.
    public func reveal(sessionId: String, itemId: String) async throws -> RevealedAnswer {
        struct Body: Encodable { let itemId: String }
        return try await send(.post, "/\(sessionId)/reveal", body: Body(itemId: itemId), as: RevealedAnswer.self)
    }

    /// Asks what went wrong with an answer already given.
    public func analyze(
        sessionId: String,
        itemId: String,
        workText: String? = nil,
        useAi: Bool = true
    ) async throws -> AnswerAnalysis {
        struct Body: Encodable {
            let itemId: String
            let workText: String?
            let useAi: Bool
        }

        return try await send(
            .post, "/\(sessionId)/analyze",
            body: Body(itemId: itemId, workText: workText, useAi: useAi),
            as: AnswerAnalysis.self
        )
    }

    // MARK: Resuming and ending

    /// The session as it stands.
    ///
    /// This is how a session is resumed — never from anything the app kept.
    /// The same seed re-renders the same question, so the student comes back to
    /// exactly what they left, including how many attempts they have spent.
    public func session(_ sessionId: String) async throws -> PracticeSession {
        try await get("/\(sessionId)", as: PracticeSession.self)
    }

    /// Stops the session without finishing it.
    @discardableResult
    public func end(_ sessionId: String) async throws -> PracticeSession {
        try await send(.post, "/\(sessionId)/end", body: EmptyBody(), as: PracticeSession.self)
    }

    public func history(status: String? = nil) async throws -> [PracticeSession] {
        var query = [URLQueryItem(name: "organizationId", value: organizationId)]
        if let status { query.append(URLQueryItem(name: "status", value: status)) }
        return try await get("", query: query, as: [PracticeSession].self)
    }

    /// Reports a question, hint or analysis as wrong or inappropriate.
    ///
    /// Required by the start guide §2.8, and it is the only route a student has
    /// when the thing in front of them is wrong. It must never fail loudly at
    /// them, so callers treat a failure here as sent.
    public func report(sessionId: String, _ report: ContentReport) async throws {
        try await sendIgnoringBody(.post, "/\(sessionId)/report", body: report)
    }

    // MARK: - Plumbing

    private struct EmptyBody: Encodable {}

    private func url(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        let base = environment.manabu2BaseURL.appending(path: "/api/v1/me/learning-sessions" + path)
        guard !query.isEmpty else { return base }

        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.queryItems = query
        guard let url = components?.url else {
            throw APIError.unknown("Could not build the practice URL.")
        }
        return url
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], as type: T.Type) async throws -> T {
        try await http.sendDecoding(
            HTTPRequest(method: .get, url: try url(path, query: query), headers: ["Accept": "application/json"]),
            as: T.self
        )
    }

    private func request<Body: Encodable>(
        _ method: HTTPRequest.Method, _ path: String, body: Body
    ) throws -> HTTPRequest {
        HTTPRequest(
            method: method,
            url: try url(path),
            headers: ["Content-Type": "application/json", "Accept": "application/json"],
            body: try JSONEncoder.wakaRoute.encode(body)
        )
    }

    private func send<Body: Encodable, T: Decodable>(
        _ method: HTTPRequest.Method, _ path: String, body: Body, as type: T.Type
    ) async throws -> T {
        try await http.sendDecoding(try request(method, path, body: body), as: T.self)
    }

    /// For the calls that answer 204. `sendDecoding` cannot be used — there is
    /// no body to decode.
    private func sendIgnoringBody<Body: Encodable>(
        _ method: HTTPRequest.Method, _ path: String, body: Body
    ) async throws {
        let response = try await http.send(try request(method, path, body: body))

        guard (200..<300).contains(response.status) else {
            let problem = try? JSONDecoder().decode(ProblemDetails.self, from: response.body)
            throw APIError.http(status: response.status, problem: problem)
        }
    }
}
