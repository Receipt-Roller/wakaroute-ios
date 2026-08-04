import Foundation

/// Reads the learning hierarchy: 教科 → パス → コース → レッスン.
public struct ContentClient: Sendable {
    private let http: any HTTPClient
    let environment: AppEnvironment

    /// Exposed so the history extension can reuse the same transport.
    var httpClient: any HTTPClient { http }

    public init(http: AuthenticatedHTTPClient, environment: AppEnvironment) {
        self.http = http
        self.environment = environment
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], as type: T.Type) async throws -> T {
        var components = URLComponents(
            url: environment.manabu2BaseURL.appending(path: path),
            resolvingAgainstBaseURL: false
        )
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else {
            throw APIError.unknown("Could not build \(path)")
        }
        return try await http.sendDecoding(
            HTTPRequest(method: .get, url: url, headers: ["Accept": "application/json"]),
            as: T.self
        )
    }

    /// ワカルート's paths, with their 教科 labels and course counts.
    ///
    /// **The only endpoint that reports labels correctly today.** Confirmed by
    /// the MANABU2 team on LMS-DEV t-d1bea77: `CatalogService.GetPathsAsync`
    /// hardcodes `CourseCount = 0` and never assigns `Labels`, so
    /// `GET /api/v1/paths` reports `[]` and `0` for every path whether or not
    /// it has either. Reading that endpoint would show all five subjects as
    /// empty, with no error to diagnose.
    ///
    /// Confirmed safe to depend on: it needs `read:catalog`, which a
    /// device-registered learner has, and it gates on organization
    /// *membership* rather than an admin role. Not admin-scoped, with no plan
    /// to make it so.
    ///
    /// Two consequences of using it:
    /// - It returns `PathDto`, not the paged listing's `PathSummaryDto`. The
    ///   fields we read exist on both, so the model spans them.
    /// - It is **not paged** — every path in the organization, in one response.
    ///   Fine at 20; revisit if that ever reaches the hundreds.
    ///
    /// When the fix ships, `GET /api/v1/paths` returns the same values and this
    /// can move back without a shape change.
    public func paths() async throws -> [LearningPathSummary] {
        try await get(
            "/api/v1/organizations/\(environment.organizationId)/paths",
            as: [LearningPathSummary].self
        )
    }

    public func path(id: String) async throws -> LearningPathDetail {
        try await get("/api/v1/paths/\(id)", as: LearningPathDetail.self)
    }

    public func course(id: String) async throws -> CourseDetail {
        try await get("/api/v1/courses/\(id)", as: CourseDetail.self)
    }

    public func lesson(id: String) async throws -> LessonDetail {
        try await get("/api/v1/lessons/\(id)", as: LessonDetail.self)
    }

    /// Per-course progress for the signed-in learner.
    public func myProgress() async throws -> [CourseProgress] {
        try await get("/api/v1/me/progress", as: [CourseProgress].self)
    }

    /// One course's progress, including which individual lessons are done.
    public func courseProgress(id: String) async throws -> CourseProgress {
        try await get("/api/v1/me/progress/\(id)", as: CourseProgress.self)
    }

    // MARK: - Recording

    /// Records that a lesson was opened.
    public func recordView(lessonId: String) async throws {
        _ = try await post("/api/v1/lessons/\(lessonId)/view")
    }

    /// Marks a lesson complete.
    ///
    /// A claim about the student's learning, so it is only ever sent on a
    /// genuine finish — never on scroll position or on leaving the screen.
    public func markComplete(lessonId: String) async throws {
        _ = try await post("/api/v1/lessons/\(lessonId)/complete")
    }

    /// Submits quiz answers and returns the graded result.
    ///
    /// The `Idempotency-Key` is not optional in practice. Every call creates an
    /// attempt, attempts gate certificates, and a resend after a timeout would
    /// otherwise record a second one. The caller passes the same key on retry.
    public func submitQuiz(
        lessonId: String,
        answers: [QuizAnswer],
        idempotencyKey: String
    ) async throws -> QuizResult {
        struct Body: Encodable { let answers: [QuizAnswer] }

        let response = try await post(
            "/api/v1/lessons/\(lessonId)/quiz/submit",
            body: try JSONEncoder().encode(Body(answers: answers)),
            idempotencyKey: idempotencyKey
        )

        do {
            return try JSONDecoder.wakaRoute.decode(QuizResult.self, from: response.body)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    /// Exposed so `LessonFeedback` can reuse the same POST handling while
    /// living in its own file — the endpoint is unconfirmed (t-d1bea84) and is
    /// easier to change kept apart from the settled ones.
    @discardableResult
    func postFeedback(lessonId: String, body: Data, idempotencyKey: String) async throws -> HTTPResponse {
        try await post("/api/v1/lessons/\(lessonId)/feedback", body: body, idempotencyKey: idempotencyKey)
    }

    @discardableResult
    private func post(_ path: String, body: Data? = nil, idempotencyKey: String? = nil) async throws -> HTTPResponse {
        var headers = ["Accept": "application/json"]
        if body != nil { headers["Content-Type"] = "application/json" }
        if let idempotencyKey { headers["Idempotency-Key"] = idempotencyKey }

        let response = try await http.send(
            HTTPRequest(
                method: .post,
                url: environment.manabu2BaseURL.appending(path: path),
                headers: headers,
                body: body
            )
        )

        guard (200..<300).contains(response.status) else {
            let problem = try? JSONDecoder().decode(ProblemDetails.self, from: response.body)
            throw APIError.http(status: response.status, problem: problem)
        }
        return response
    }
}
