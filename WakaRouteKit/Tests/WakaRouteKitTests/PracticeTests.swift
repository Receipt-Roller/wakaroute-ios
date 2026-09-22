import Foundation
import Testing
@testable import WakaRouteKit

/// Shaped from 「AI学習基盤 — WakaRoute スタートガイド」 §2.2, which is the only
/// description of this response that exists: the ワカルート organisation has no
/// 理解要素 and no question bank yet (checked 2026-09-22), so there is no live
/// session to capture. **These payloads are read from the contract, not from a
/// server**, and that is the one thing about this suite worth knowing.
private let activeSession = """
{
  "id": "s-1", "status": "active", "endReason": null,
  "remainingSeconds": 540, "itemCount": 10, "answeredCount": 2, "correctCount": 1,
  "allowHints": true, "maxAttempts": 3,
  "targets": [
    { "conceptId": "c-1", "code": "math.add-negative", "name": "正の数・負の数の加法",
      "attempts": 2, "correct": 1, "estimate": 0.42, "mastered": false, "isPrerequisite": false }
  ],
  "current": {
    "id": "item-3", "ordinal": 3, "conceptCode": "math.add-negative", "difficulty": 2,
    "attemptCount": 0, "attemptsLeft": 3, "hintsUsed": 0, "hintsGiven": [], "canHint": true,
    "question": {
      "questionId": "q-9", "version": 1, "seed": 4821, "kind": "single",
      "stem": "(-3) + 5 を計算しなさい。",
      "options": [{ "key": "A", "text": "-8" }, { "key": "B", "text": "2" }, { "key": "C", "text": "8" }],
      "variables": { "a": -3, "b": 5 }
    }
  }
}
"""

private func decodeSession(_ json: String) throws -> PracticeSession {
    try JSONDecoder.wakaRoute.decode(PracticeSession.self, from: Data(json.utf8))
}

@Suite("Practice session decoding")
struct PracticeDecodingTests {

    @Test("Decodes a session with its current question")
    func decodesActiveSession() throws {
        let session = try decodeSession(activeSession)

        #expect(session.id == "s-1")
        #expect(session.status == .active)
        #expect(session.remainingSeconds == 540)
        #expect(session.targets.first?.name == "正の数・負の数の加法")
        #expect(session.current?.id == "item-3")
        #expect(session.current?.question.kind == .single)
        #expect(session.current?.question.options.map(\.key) == ["A", "B", "C"])
        #expect(!session.isFinished)
    }

    /// The template's variables come back as numbers, not strings. Decoding
    /// them strictly would fail the whole question over a display detail.
    @Test("Question variables decode whether sent as numbers or strings")
    func variablesAreFlexible() throws {
        let session = try decodeSession(activeSession)

        #expect(session.current?.question.variables?["a"] == "-3")
        #expect(session.current?.question.variables?["b"] == "5")
    }

    /// The single most important property of this type.
    @Test("A question carries no answer")
    func questionHasNoAnswer() throws {
        let session = try decodeSession(activeSession)
        let question = try #require(session.current?.question)

        // Nothing on the rendered question can say which option is right —
        // there is no property to hold it, and the payload has no such field.
        #expect(!activeSession.contains("correctAnswer"))
        #expect(question.options.count == 3)
    }

    @Test("A finished session has no current question")
    func finishedSession() throws {
        let session = try decodeSession("""
        { "id": "s-1", "status": "completed", "endReason": "limit", "itemCount": 10,
          "answeredCount": 10, "correctCount": 7, "allowHints": true, "maxAttempts": 3,
          "targets": [], "current": null }
        """)

        #expect(session.isFinished)
        #expect(session.endReason == .limit)
        #expect(session.current == nil)
    }

    /// §3 of the coach contract: adding an enum value is non-breaking, and the
    /// client must draw an unknown one as その他 rather than fail. A session
    /// that will not decode is a student stranded mid-question.
    @Test("An unknown status or outcome decodes instead of failing")
    func unknownEnumsSurvive() throws {
        let session = try decodeSession("""
        { "id": "s-1", "status": "paused", "endReason": "interrupted", "itemCount": 1,
          "answeredCount": 0, "correctCount": 0, "allowHints": true, "maxAttempts": 3,
          "targets": [], "current": null }
        """)

        #expect(session.status == SessionStatus("paused"))
        #expect(!session.status.isActive, "Anything that is not 'active' must not be treated as active.")
        #expect(session.endReason == SessionEndReason("interrupted"))
    }

    @Test("Decodes a wrong answer that can still be retried, with no answer in it")
    func decodesRetryableWrongAnswer() throws {
        let result = try JSONDecoder.wakaRoute.decode(AnswerResult.self, from: Data("""
        { "isCorrect": false, "misconception": "sign-flip", "canRetry": true, "attemptsLeft": 2,
          "outcome": null, "correctAnswerText": null, "explanation": null,
          "session": \(activeSession) }
        """.utf8))

        #expect(!result.isCorrect)
        #expect(result.canRetry)
        #expect(result.misconception == "sign-flip")
        #expect(result.correctAnswerText == nil, "The answer must not arrive while the question is still open.")
    }

    @Test("Decodes a closed question, which does carry the answer")
    func decodesClosedAnswer() throws {
        let result = try JSONDecoder.wakaRoute.decode(AnswerResult.self, from: Data("""
        { "isCorrect": true, "misconception": null, "canRetry": false, "attemptsLeft": 0,
          "outcome": "first-try", "correctAnswerText": "2", "explanation": "…",
          "session": \(activeSession) }
        """.utf8))

        #expect(result.outcome == .firstTry)
        #expect(result.correctAnswerText == "2")
    }

    /// Only these two move mastery, and the distinction is the reason the hint
    /// ladder exists at all.
    @Test("Reaching it unaided is first-try or self, and nothing else")
    func unaidedOutcomes() {
        #expect(AnswerOutcome.firstTry.reachedUnaided)
        #expect(AnswerOutcome.selfReached.reachedUnaided)
        #expect(!AnswerOutcome.assisted.reachedUnaided)
        #expect(!AnswerOutcome.revealed.reachedUnaided)
        #expect(!AnswerOutcome.failed.reachedUnaided)
        #expect(!AnswerOutcome("something-new").reachedUnaided, "An unknown outcome is not a claim of understanding.")
    }

    @Test("Decodes a hint and what is left of the ladder")
    func decodesHint() throws {
        let hint = try JSONDecoder.wakaRoute.decode(PracticeHint.self, from: Data("""
        { "tier": "small", "step": 2, "text": "数直線で、-3 から右に 5 動かしてみましょう。",
          "isFallback": false, "prerequisiteConceptCode": null, "similarQuestion": null,
          "remaining": ["prerequisite", "rephrase", "similar"] }
        """.utf8))

        #expect(hint.tier == .small)
        #expect(hint.remaining == [.prerequisite, .rephrase, .similar])
        #expect(hint.similarQuestion == nil)
    }

    /// The 類題 comes with its own answer. That is not a leak: it is a
    /// different question, and seeing one worked through is the last rung
    /// before giving up.
    @Test("A similar question carries its own answer, not this one's")
    func decodesSimilarQuestion() throws {
        let hint = try JSONDecoder.wakaRoute.decode(PracticeHint.self, from: Data("""
        { "tier": "similar", "step": 5, "text": "似た問題です。", "isFallback": false,
          "similarQuestion": { "stem": "(-2) + 6 は？", "options": [],
                               "correctAnswerText": "4", "explanation": "-2 から右に 6。" },
          "remaining": [] }
        """.utf8))

        #expect(hint.similarQuestion?.correctAnswerText == "4")
        #expect(hint.remaining.isEmpty, "Nothing after this but revealing it.")
    }

    @Test("Decodes an analysis")
    func decodesAnalysis() throws {
        let analysis = try JSONDecoder.wakaRoute.decode(AnswerAnalysis.self, from: Data("""
        { "category": "misconception", "confidence": 0.81, "misconception": "sign-flip",
          "misconceptionDescription": "符号の扱いがずれています。", "prerequisiteConceptCode": null,
          "evidence": ["-8 は 3 + 5 に負号をつけた形"], "suggestion": "数直線で確かめてみましょう。",
          "correctAnswerText": "2", "source": "rule+ai" }
        """.utf8))

        #expect(analysis.category == .misconception)
        #expect(analysis.isConfident)
        #expect(analysis.evidence.count == 1)
    }

    /// The guide is explicit: under 0.5 is 「わからない」. Presenting a guess as a
    /// finding would tell a student something about themselves that nothing
    /// actually knows.
    @Test("A low-confidence analysis is not a finding")
    func lowConfidenceIsNotAFinding() throws {
        let analysis = try JSONDecoder.wakaRoute.decode(AnswerAnalysis.self, from: Data("""
        { "category": "careless", "confidence": 0.31, "evidence": [], "source": "rule" }
        """.utf8))

        #expect(!analysis.isConfident)
        #expect(AnswerAnalysis.confidenceFloor == 0.5)
    }
}

// MARK: - Client

private final class PracticeStubClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [HTTPRequest] = []
    var status = 200
    var body = "{}"

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

        lock.withLock { requests.append(request) }
        return HTTPResponse(status: status, body: Data(body.utf8))
    }
}

/// A stand-in organisation, so the tests never assert against the real one.
private let testEnvironment = AppEnvironment(
    manabu2BaseURL: URL(string: "https://api.manabu2.com")!,
    wakarouteBaseURL: URL(string: "https://wakaroute.com")!,
    clientId: "wakaroute",
    organizationId: "org-test",
    keychainService: "com.wakaroute.test"
)

private func makePractice(_ http: PracticeStubClient) -> PracticeClient {
    let store = InMemorySecretStore()
    let auth = AuthSession(
        client: DeviceAuthClient(http: http, environment: testEnvironment),
        store: store,
        deviceIdProvider: StoredDeviceIdProvider(store: store)
    )
    return PracticeClient(
        http: AuthenticatedHTTPClient(underlying: http, session: auth),
        environment: testEnvironment
    )
}

private func body(of request: HTTPRequest) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any] ?? [:]
}

@Suite("Practice client")
struct PracticeClientTests {

    /// A start that times out and is retried must resume the session the server
    /// already opened, not strand it and begin a second one the student never
    /// sees.
    @Test("Every start carries the caller's clientReference")
    func startCarriesClientReference() async throws {
        let http = PracticeStubClient()
        http.body = activeSession

        _ = try await makePractice(http).start(
            conceptCodes: ["math.add-negative"], clientReference: "wr-abc"
        )

        let sent = try body(of: try #require(http.requests.last))
        #expect(sent["clientReference"] as? String == "wr-abc")
        #expect(sent["organizationId"] as? String == "org-test")
        #expect(sent["mode"] as? String == "adaptive")
    }

    /// Letting the client choose the seed would let it choose the question.
    @Test("No seed is ever sent")
    func neverSendsSeed() async throws {
        let http = PracticeStubClient()
        http.body = activeSession

        _ = try await makePractice(http).start(conceptCodes: ["c"], clientReference: "wr-1")

        #expect(try body(of: try #require(http.requests.last))["seed"] == nil)
    }

    /// review works out its own targets. Sending concept codes with it would be
    /// asking for something else entirely.
    @Test("review mode sends no concept codes")
    func reviewSendsNoConcepts() async throws {
        let http = PracticeStubClient()
        http.body = activeSession

        _ = try await makePractice(http).start(
            mode: .review, conceptCodes: ["math.add-negative"], clientReference: "wr-2"
        )

        let sent = try body(of: try #require(http.requests.last))
        #expect(sent["mode"] as? String == "review")
        #expect(sent["conceptCodes"] == nil)
    }

    @Test("A chosen option is sent as a key, typed text as text")
    func answerShapes() async throws {
        let http = PracticeStubClient()
        http.body = """
        { "isCorrect": true, "canRetry": false, "attemptsLeft": 0, "outcome": "first-try",
          "session": \(activeSession) }
        """
        let client = makePractice(http)

        _ = try await client.answer(sessionId: "s-1", itemId: "item-3", answer: .option(key: "B"), timeMs: 12000)
        let chosen = try body(of: try #require(http.requests.last))
        #expect((chosen["answer"] as? [String: Any])?["key"] as? String == "B")
        #expect(chosen["timeMs"] as? Int == 12000)

        _ = try await client.answer(sessionId: "s-1", itemId: "item-3", answer: .written("-3"), timeMs: 900)
        let typed = try body(of: try #require(http.requests.last))
        #expect((typed["answer"] as? [String: Any])?["text"] as? String == "-3")
    }

    @Test("Answers go to the session's answer path with the item id")
    func answerPath() async throws {
        let http = PracticeStubClient()
        http.body = """
        { "isCorrect": false, "canRetry": true, "attemptsLeft": 2, "session": \(activeSession) }
        """

        _ = try await makePractice(http).answer(
            sessionId: "s-1", itemId: "item-3", answer: .option(key: "A"), timeMs: 1
        )

        let request = try #require(http.requests.last)
        #expect(request.url.path().hasSuffix("/me/learning-sessions/s-1/answer"))
        #expect(try body(of: request)["itemId"] as? String == "item-3")
    }

    /// Resuming reads the server, never a local copy — §6.3. The same seed
    /// re-renders the same question, spent attempts and all.
    @Test("Resuming reads the session back from the server")
    func resumeReadsServer() async throws {
        let http = PracticeStubClient()
        http.body = activeSession

        let session = try await makePractice(http).session("s-1")

        #expect(http.requests.last?.method == .get)
        #expect(http.requests.last?.url.path().hasSuffix("/me/learning-sessions/s-1") == true)
        #expect(session.current?.question.seed == 4821)
    }

    @Test("A report is sent even when the server answers with no body")
    func reportHandlesEmptyResponse() async throws {
        let http = PracticeStubClient()
        http.status = 204
        http.body = ""

        try await makePractice(http).report(
            sessionId: "s-1",
            ContentReport(itemId: "item-3", targetKind: "hint", targetId: "small", reason: "wrong")
        )

        let sent = try body(of: try #require(http.requests.last))
        #expect(sent["targetKind"] as? String == "hint")
        #expect(sent["reason"] as? String == "wrong")
    }

    /// In review mode this is the good news — nothing is due. The screen has to
    /// be able to tell that apart from a failure.
    @Test("Refusals arrive as codes the screen can act on")
    func mapsRefusals() async throws {
        let http = PracticeStubClient()
        http.status = 409
        http.body = #"{ "status": 409, "code": "no_questions" }"#

        do {
            _ = try await makePractice(http).start(conceptCodes: ["c"], clientReference: "wr-3")
            Issue.record("Expected the server's refusal")
        } catch {
            #expect(PracticeRefusal(error) == .noQuestions)
        }
    }

    @Test("Running out of hints is distinguishable from hints being off")
    func hintRefusals() async throws {
        let http = PracticeStubClient()
        http.status = 409

        http.body = #"{ "code": "no_more_hints" }"#
        do {
            _ = try await makePractice(http).hint(sessionId: "s-1", itemId: "item-3")
            Issue.record("Expected a refusal")
        } catch {
            #expect(PracticeRefusal(error) == .noMoreHints)
        }

        http.body = #"{ "code": "hints_off" }"#
        do {
            _ = try await makePractice(http).hint(sessionId: "s-1", itemId: "item-3")
            Issue.record("Expected a refusal")
        } catch {
            #expect(PracticeRefusal(error) == .hintsOff)
        }
    }
}
