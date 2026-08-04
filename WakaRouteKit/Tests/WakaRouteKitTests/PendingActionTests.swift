import Foundation
import Testing
@testable import WakaRouteKit

/// Answers auth, and can be told to fail or reject the learning calls.
private final class ActionStubClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calledPaths: [String] = []
    /// nil succeeds; otherwise this status is returned for learning calls.
    var failureStatus: Int?

    private static let registration = """
    { "deviceSecret": "s", "isNewAccount": true,
      "auth": { "accessToken": "a", "expiresAt": "2033-01-01T00:00:00Z",
                "refreshToken": "r", "scopes": ["write:progress"],
                "user": { "id": "u", "email": "", "displayName": "" } } }
    """

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let path = request.url.path()
        if path.hasSuffix("/devices/register") || path.hasSuffix("/devices/token") || path.hasSuffix("/auth/refresh") {
            return HTTPResponse(status: 200, body: Data(Self.registration.utf8))
        }

        lock.withLock { calledPaths.append(path) }

        if let failureStatus = lock.withLock({ failureStatus }) {
            return HTTPResponse(status: failureStatus, body: Data("{}".utf8))
        }
        return HTTPResponse(
            status: 200,
            body: Data(#"{"attemptId":"a1","quizId":"q1","scorePercent":80,"passingScorePercent":80,"isPassed":true}"#.utf8)
        )
    }
}

private func makeQueue(
    actions: [PendingAction] = [],
    store: InMemoryPendingActionStore? = nil,
    http: ActionStubClient
) -> LearningActionQueue {
    let secrets = InMemorySecretStore()
    let auth = AuthSession(
        client: DeviceAuthClient(http: http, environment: .production),
        store: secrets,
        deviceIdProvider: StoredDeviceIdProvider(store: secrets)
    )
    let content = ContentClient(
        http: AuthenticatedHTTPClient(underlying: http, session: auth),
        environment: .production
    )
    return LearningActionQueue(store: store ?? InMemoryPendingActionStore(actions: actions), content: content)
}

private func action(_ kind: PendingAction.Kind, lesson: String, secondsAgo: Int = 0) -> PendingAction {
    PendingAction(
        kind: kind,
        lessonId: lesson,
        createdAt: Date(timeIntervalSince1970: 1_785_000_000 - TimeInterval(secondsAgo)),
        answers: kind == .quizSubmit ? [QuizAnswer(questionId: "q1", optionId: "o1")] : nil
    )
}

@Suite("Offline lesson feedback")
struct PendingFeedbackTests {

    /// Unlike a quiz attempt, a second opinion is not a second event — it is a
    /// correction. Sending the abandoned one afterwards would overwrite the
    /// answer the student actually meant.
    @Test("Re-rating replaces the queued answer rather than queueing both")
    func rerateReplaces() async throws {
        let store = InMemoryPendingActionStore()
        let queue = makeQueue(store: store, http: ActionStubClient())

        await queue.enqueue(PendingAction(kind: .feedback, lessonId: "l-1", feedback: LessonFeedback(understood: false)))
        await queue.enqueue(PendingAction(kind: .feedback, lessonId: "l-1", feedback: LessonFeedback(understood: true)))

        let queued = try store.load().filter { $0.kind == .feedback }
        #expect(queued.count == 1, "One lesson, one opinion.")
        #expect(queued.first?.feedback?.understood == true, "The later answer is the one they meant.")
    }

    @Test("Feedback for a different lesson is kept separately")
    func differentLessonsCoexist() async throws {
        let store = InMemoryPendingActionStore()
        let queue = makeQueue(store: store, http: ActionStubClient())

        await queue.enqueue(PendingAction(kind: .feedback, lessonId: "l-1", feedback: LessonFeedback(understood: true)))
        await queue.enqueue(PendingAction(kind: .feedback, lessonId: "l-2", feedback: LessonFeedback(understood: false)))

        #expect(try store.load().filter { $0.kind == .feedback }.count == 2)
    }

    /// The reasons and the comment have to survive being written to disk, or a
    /// student on a train tells us nothing.
    @Test("Reasons and the comment survive the round trip")
    func feedbackRoundTrip() throws {
        let action = PendingAction(
            kind: .feedback,
            lessonId: "l-1",
            feedback: LessonFeedback(
                understood: false,
                reasons: [.explanation, .examples],
                comment: "数直線のところ"
            )
        )

        let data = try JSONEncoder.wakaRoute.encode([action])
        let decoded = try JSONDecoder.wakaRoute.decode([PendingAction].self, from: data)

        #expect(decoded.first?.feedback?.reasons == [.explanation, .examples])
        #expect(decoded.first?.feedback?.comment == "数直線のところ")
    }

    /// Over the server's limit is a 400, and the queue treats a 400 as
    /// permanent — so an over-long answer would be set aside and never sent.
    /// The screen stops them getting there; this is the last resort, and losing
    /// the tail of a sentence beats losing the whole answer.
    @Test("A comment longer than the server accepts is clamped, not lost")
    func longCommentIsClamped() {
        let feedback = LessonFeedback(
            understood: false,
            comment: String(repeating: "あ", count: LessonFeedback.commentLimit + 500)
        )

        #expect(feedback.comment?.count == LessonFeedback.commentLimit)
    }

    /// The server discards reasons on a 「わかった」 and clears any it had stored.
    /// Sending them anyway would make the request say something it does not.
    @Test("Reasons are dropped when the answer is わかった")
    func reasonsClearedWhenUnderstood() {
        let feedback = LessonFeedback(understood: true, reasons: [.explanation])
        #expect(feedback.reasons.isEmpty)
    }

    /// The exact body the server accepts, verified against production on
    /// 2026-08-04. `understood` missing is a 400, so it must always be present;
    /// an absent comment must be omitted rather than sent as null.
    @Test("The request body matches what the server accepts")
    func bodyShape() throws {
        let full = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(
                LessonFeedback(understood: false, reasons: [.explanation, .length], comment: "むずかしい")
            )
        ) as? [String: Any]

        #expect(full?["understood"] as? Bool == false)
        #expect(full?["reasons"] as? [String] == ["explanation", "length"])
        #expect(full?["comment"] as? String == "むずかしい")

        let bare = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(LessonFeedback(understood: true))
        ) as? [String: Any]

        #expect(bare?["understood"] as? Bool == true)
        #expect(bare?.keys.contains("comment") == false, "Absent, not null.")
    }

    /// The server's list of reasons may grow before the app does.
    @Test("An unfamiliar reason is dropped rather than throwing away the answer")
    func unknownReasonIsTolerated() throws {
        let json = #"{ "understood": false, "reasons": ["explanation", "pace"], "comment": "x" }"#
        let feedback = try JSONDecoder.wakaRoute.decode(LessonFeedback.self, from: Data(json.utf8))

        #expect(feedback.reasons == [.explanation])
        #expect(feedback.comment == "x", "The rest of the answer survives.")
    }
}

@Suite("Offline replay")
struct PendingActionTests {

    @Test("An empty queue does nothing")
    func emptyQueue() async {
        let http = ActionStubClient()
        #expect(await makeQueue(http: http).run() == .nothingToDo)
        #expect(http.calledPaths.isEmpty)
    }

    @Test("Everything queued is replayed and cleared")
    func replaysAndClears() async {
        let http = ActionStubClient()
        let queue = makeQueue(
            actions: [action(.complete, lesson: "l1"), action(.quizSubmit, lesson: "l2")],
            http: http
        )

        #expect(await queue.run() == .sent(count: 2))
        #expect(await queue.pendingCount == 0)
        #expect(http.calledPaths.contains { $0.hasSuffix("/complete") })
        #expect(http.calledPaths.contains { $0.hasSuffix("/quiz/submit") })
    }

    /// Oldest first, so a student's actions arrive in the order they happened.
    @Test("Replay runs oldest first")
    func oldestFirst() async {
        let http = ActionStubClient()
        let queue = makeQueue(
            actions: [action(.complete, lesson: "newer"), action(.complete, lesson: "older", secondsAgo: 600)],
            http: http
        )

        _ = await queue.run()
        #expect(http.calledPaths.first?.contains("older") == true)
    }

    @Test("A transient failure leaves everything queued for next time")
    func transientFailureKeepsQueue() async {
        let http = ActionStubClient()
        http.failureStatus = 503
        let queue = makeQueue(actions: [action(.complete, lesson: "l1")], http: http)

        #expect(await queue.run() == .failed)
        #expect(await queue.pendingCount == 1)
    }

    /// A lesson deleted since the student finished it will never accept the
    /// call. Retrying forever would block everything queued behind it.
    @Test("A permanent rejection is set aside rather than retried forever")
    func permanentRejectionIsSetAside() async {
        let http = ActionStubClient()
        http.failureStatus = 404
        let queue = makeQueue(actions: [action(.complete, lesson: "gone")], http: http)

        _ = await queue.run()
        #expect(await queue.pendingCount == 0, "Set aside, so it stops blocking the queue.")

        http.failureStatus = nil
        #expect(await queue.run() == .nothingToDo, "And never retried.")
    }

    /// Completing the same lesson twice is one fact, not two.
    @Test("Duplicate view and complete actions collapse")
    func duplicatesCollapse() async {
        let http = ActionStubClient()
        let queue = makeQueue(http: http)

        await queue.enqueue(action(.complete, lesson: "l1"))
        await queue.enqueue(action(.complete, lesson: "l1"))
        await queue.enqueue(action(.view, lesson: "l1"))
        await queue.enqueue(action(.view, lesson: "l1"))

        #expect(await queue.pendingCount == 2, "One complete and one view.")
    }

    /// Each quiz attempt is its own answers and its own score. Collapsing them
    /// would silently drop a student's second try.
    @Test("Quiz submissions are never collapsed")
    func quizSubmissionsAreDistinct() async {
        let http = ActionStubClient()
        let queue = makeQueue(http: http)

        await queue.enqueue(action(.quizSubmit, lesson: "l1"))
        await queue.enqueue(action(.quizSubmit, lesson: "l1"))

        #expect(await queue.pendingCount == 2)
    }

    /// The key is stored with the action, so a replay days later is still the
    /// same attempt rather than a second one.
    @Test("A queued quiz keeps its idempotency key across replays")
    func keepsIdempotencyKey() async throws {
        let original = PendingAction(
            kind: .quizSubmit, lessonId: "l1",
            answers: [QuizAnswer(questionId: "q", optionId: "o")],
            idempotencyKey: "fixed-key"
        )
        let data = try JSONEncoder.wakaRoute.encode([original])
        let decoded = try JSONDecoder.wakaRoute.decode([PendingAction].self, from: data)

        #expect(decoded.first?.idempotencyKey == "fixed-key")
        #expect(decoded.first?.answers?.first?.optionId == "o")
    }

    @Test("A queue file from an earlier version still loads")
    func decodesOlderQueueFile() throws {
        let json = """
        [ { "id": "0FB9E0B4-2E3A-4B36-9C6F-6C7D1E2A3B44", "kind": "complete",
            "lessonId": "l1", "createdAt": "2026-08-01T11:00:00Z" } ]
        """
        let actions = try JSONDecoder.wakaRoute.decode([PendingAction].self, from: Data(json.utf8))

        #expect(actions.count == 1)
        #expect(actions[0].isRejected == false)
        #expect(actions[0].answers == nil)
    }
}
