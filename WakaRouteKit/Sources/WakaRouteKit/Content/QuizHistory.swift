import Foundation

/// One past quiz attempt, from `GET /api/v1/me/quiz-attempts`.
///
/// Carries the lesson and course titles, so a history list needs no extra call
/// per row.
public struct QuizAttempt: Decodable, Sendable, Equatable, Identifiable {
    public var id: String { attemptId }
    public let attemptId: String
    public let quizId: String?
    public let lessonId: String?
    public let lessonTitle: String?
    public let courseId: String?
    public let courseTitle: String?
    public let scorePercent: Int
    public let passingScorePercent: Int
    public let isPassed: Bool
    public let startedAt: Date?
    public let completedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case attemptId, quizId, lessonId, lessonTitle, courseId, courseTitle
        case scorePercent, passingScorePercent, isPassed, startedAt, completedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        attemptId = try c.decode(String.self, forKey: .attemptId)
        quizId = try c.decodeIfPresent(String.self, forKey: .quizId)
        lessonId = try c.decodeIfPresent(String.self, forKey: .lessonId)
        lessonTitle = try c.decodeIfPresent(String.self, forKey: .lessonTitle)
        courseId = try c.decodeIfPresent(String.self, forKey: .courseId)
        courseTitle = try c.decodeIfPresent(String.self, forKey: .courseTitle)
        scorePercent = try c.decodeIfPresent(FlexibleInt.self, forKey: .scorePercent)?.value ?? 0
        passingScorePercent = try c.decodeIfPresent(FlexibleInt.self, forKey: .passingScorePercent)?.value ?? 0
        isPassed = try c.decodeIfPresent(Bool.self, forKey: .isPassed) ?? false
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
    }
}

/// One past 確認テスト attempt, from `GET /api/v1/me/test-attempts`.
///
/// Deliberately the same shape as `QuizAttempt`, plus the timing fields that
/// only tests carry.
public struct TestAttempt: Decodable, Sendable, Equatable, Identifiable {
    public var id: String { resultId }
    public let resultId: String
    public let testId: String?
    public let testTitle: String?
    public let pathId: String?
    public let scorePercent: Int
    public let passingScorePercent: Int
    public let isPassed: Bool
    public let correctCount: Int?
    public let totalQuestions: Int?
    public let completedAt: Date?

    public let timeLimitSeconds: Int?
    public let elapsedSeconds: Int?
    /// Nil when it cannot be judged — no limit set, or no elapsed time
    /// reported. Nil is not "within"; it means unknown.
    public let isWithinTimeLimit: Bool?

    private enum CodingKeys: String, CodingKey {
        case resultId, testId, testTitle, pathId, scorePercent, passingScorePercent
        case isPassed, correctCount, totalQuestions, completedAt
        case timeLimitSeconds, elapsedSeconds, isWithinTimeLimit
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        resultId = try c.decode(String.self, forKey: .resultId)
        testId = try c.decodeIfPresent(String.self, forKey: .testId)
        testTitle = try c.decodeIfPresent(String.self, forKey: .testTitle)
        pathId = try c.decodeIfPresent(String.self, forKey: .pathId)
        scorePercent = try c.decodeIfPresent(FlexibleInt.self, forKey: .scorePercent)?.value ?? 0
        passingScorePercent = try c.decodeIfPresent(FlexibleInt.self, forKey: .passingScorePercent)?.value ?? 0
        isPassed = try c.decodeIfPresent(Bool.self, forKey: .isPassed) ?? false
        correctCount = try c.decodeIfPresent(FlexibleInt.self, forKey: .correctCount)?.value
        totalQuestions = try c.decodeIfPresent(FlexibleInt.self, forKey: .totalQuestions)?.value
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        timeLimitSeconds = try c.decodeIfPresent(FlexibleInt.self, forKey: .timeLimitSeconds)?.value
        elapsedSeconds = try c.decodeIfPresent(FlexibleInt.self, forKey: .elapsedSeconds)?.value
        isWithinTimeLimit = try c.decodeIfPresent(Bool.self, forKey: .isWithinTimeLimit)
    }

    /// Passed, but over the time limit.
    ///
    /// Worth distinguishing: 「時間内に安定する」 is the top level of the
    /// 理解マップ, so passing slowly is a different state from passing.
    public var passedButOverTime: Bool {
        isPassed && isWithinTimeLimit == false
    }
}

extension ContentClient {
    /// Past quiz attempts, newest first.
    ///
    /// `from` and `to` are **Japanese calendar days and inclusive** — the
    /// server's rule. `from == to` returns that single day. Attempts that were
    /// started but never submitted are excluded, so an abandoned quiz never
    /// appears as a failure the student did not sit.
    public func quizAttempts(from: String, to: String, limit: Int = 200) async throws -> [QuizAttempt] {
        try await attempts("/api/v1/me/quiz-attempts", from: from, to: to, limit: limit, as: [QuizAttempt].self)
    }

    /// Past 確認テスト attempts, newest first. Same rules as `quizAttempts`.
    public func testAttempts(from: String, to: String, limit: Int = 200) async throws -> [TestAttempt] {
        try await attempts("/api/v1/me/test-attempts", from: from, to: to, limit: limit, as: [TestAttempt].self)
    }

    private func attempts<T: Decodable>(
        _ path: String, from: String, to: String, limit: Int, as type: T.Type
    ) async throws -> T {
        var components = URLComponents(
            url: environment.manabu2BaseURL.appending(path: path),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "from", value: from),
            URLQueryItem(name: "to", value: to),
            // The server rejects anything outside 1–500 rather than clamping,
            // so the clamp happens here.
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 500)))
        ]
        guard let url = components?.url else { throw APIError.unknown("Could not build \(path)") }

        return try await httpClient.sendDecoding(
            HTTPRequest(method: .get, url: url, headers: ["Accept": "application/json"]),
            as: T.self
        )
    }
}
