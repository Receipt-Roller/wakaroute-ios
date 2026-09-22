import Foundation
import Observation
import WakaRouteKit

/// One practice session, from the first question to the last.
///
/// Holds no copy of the question and no idea of whether an answer is right.
/// Every screen state here came back from the server, which is the only thing
/// that marks anything.
@MainActor
@Observable
final class PracticeViewModel {
    enum Phase: Equatable {
        case starting
        /// Waiting for an answer.
        case answering
        /// Wrong, and there are attempts left.
        case retry(AnswerResult)
        /// The question is closed — right, out of attempts, or revealed.
        case closed(correctAnswer: String?, explanation: String?, wasCorrect: Bool)
        case finished(PracticeSession)
        /// Nothing to ask. In review mode this is good news.
        case nothingDue
        case failed(message: String)
    }

    private(set) var phase: Phase = .starting
    private(set) var session: PracticeSession?
    /// The rungs climbed so far on the question in front of the student.
    private(set) var hints: [PracticeHint] = []
    private(set) var analysis: AnswerAnalysis?
    private(set) var isWorking = false

    /// What the student has entered but not yet sent.
    var chosenOption: String?
    var typedAnswer = ""
    /// 途中式 — optional, and only ever used to explain a wrong answer back to
    /// them.
    var workText = ""

    private let client: PracticeClient
    private let resumeStore: any PracticeResumeStore
    private let mode: PracticeMode
    private let conceptCodes: [String]

    /// When the question appeared. `timeMs` is measured from here: the server
    /// cannot see when it was drawn, and both the analysis and the mastery
    /// model are built on it.
    private var shownAt = Date()
    private var clientReference = "wr-\(UUID().uuidString)"

    init(
        client: PracticeClient,
        resumeStore: any PracticeResumeStore,
        mode: PracticeMode = .adaptive,
        conceptCodes: [String] = []
    ) {
        self.client = client
        self.resumeStore = resumeStore
        self.mode = mode
        self.conceptCodes = conceptCodes
    }

    var currentItem: PracticeItem? { session?.current }

    /// Whether the hint ladder has anything left on it.
    var canHint: Bool {
        guard let item = currentItem, session?.allowHints == true else { return false }
        return item.canHint
    }

    /// 答えを見る is offered only once the hints are gone.
    ///
    /// Not a rule imposed on the student — the ladder exists so they arrive at
    /// it themselves, and a reveal button sitting beside the first hint is just
    /// a shorter way to not learn this.
    var canReveal: Bool {
        guard currentItem != nil else { return false }
        return session?.allowHints == false || !canHint
    }

    var progressText: String {
        guard let session else { return "" }
        return "\(session.answeredCount) / \(session.itemCount)"
    }

    // MARK: Starting and resuming

    func begin() async {
        isWorking = true
        defer { isWorking = false }

        // A session left open by a previous launch is rejoined, not replaced.
        // Starting a fresh one would leave the old one hanging and lose the
        // questions already answered into it.
        if let point = try? resumeStore.load() {
            clientReference = point.clientReference
            if let resumed = try? await client.session(point.sessionId), resumed.status.isActive {
                adopt(resumed)
                return
            }
            // Gone, finished or expired. Nothing to rejoin.
            try? resumeStore.save(nil)
        }

        await startFresh()
    }

    private func startFresh() async {
        do {
            let started = try await client.start(
                mode: mode,
                conceptCodes: conceptCodes,
                clientReference: clientReference
            )
            try? resumeStore.save(
                PracticeResumePoint(sessionId: started.id, clientReference: clientReference)
            )
            adopt(started)
        } catch {
            phase = failure(for: error)
        }
    }

    // MARK: Answering

    var hasAnswer: Bool {
        guard let kind = currentItem?.question.kind else { return false }
        return kind == .single
            ? chosenOption != nil
            : !typedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func submit() async {
        guard let item = currentItem, hasAnswer, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        let answer: PracticeAnswer = item.question.kind == .single
            ? .option(key: chosenOption ?? "")
            : .written(typedAnswer.trimmingCharacters(in: .whitespacesAndNewlines))

        do {
            let result = try await client.answer(
                sessionId: try sessionId(),
                itemId: item.id,
                answer: answer,
                timeMs: Int(Date().timeIntervalSince(shownAt) * 1000)
            )
            apply(result)
        } catch {
            phase = failure(for: error)
        }
    }

    private func apply(_ result: AnswerResult) {
        session = result.session

        if result.canRetry && !result.isCorrect {
            // Same question, another go. The answer is not in this response and
            // must not be guessed at from anywhere else.
            phase = .retry(result)
            clearEntry()
            return
        }

        phase = .closed(
            correctAnswer: result.correctAnswerText,
            explanation: result.explanation,
            wasCorrect: result.isCorrect
        )
    }

    /// Moves to whatever the server has queued next.
    func advance() {
        analysis = nil
        hints = []
        workText = ""
        clearEntry()

        guard let session else { return }
        if session.isFinished {
            try? resumeStore.save(nil)
            phase = .finished(session)
        } else {
            shownAt = Date()
            phase = .answering
        }
    }

    private func clearEntry() {
        chosenOption = nil
        typedAnswer = ""
    }

    // MARK: Help

    /// Climbs one rung. The order is the server's and cannot be skipped.
    func requestHint() async {
        guard let item = currentItem, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        do {
            let hint = try await client.hint(sessionId: try sessionId(), itemId: item.id)
            hints.append(hint)
            // `canHint` lives on the item, which only changes when the session
            // does; the hint's own `remaining` is what is current.
            if let refreshed = try? await client.session(try sessionId()) {
                session = refreshed
            }
        } catch {
            // A hint that will not come is not a reason to lose the question.
            // The student can still answer, and still reveal.
            if PracticeRefusal(error) == nil { phase = failure(for: error) }
        }
    }

    func reveal() async {
        guard let item = currentItem, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        do {
            let revealed = try await client.reveal(sessionId: try sessionId(), itemId: item.id)
            session = revealed.session
            phase = .closed(
                correctAnswer: revealed.correctAnswerText,
                explanation: revealed.explanation,
                wasCorrect: false
            )
        } catch {
            phase = failure(for: error)
        }
    }

    /// Asks what went wrong. Offered after the question is closed, never
    /// before — an explanation of the mistake while they could still fix it
    /// would be the answer in disguise.
    func analyzeMistake() async {
        guard let item = currentItem, let id = try? sessionId(), !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        analysis = try? await client.analyze(
            sessionId: id,
            itemId: item.id,
            workText: workText.isEmpty ? nil : workText
        )
    }

    func report(targetKind: String, targetId: String?, reason: String, text: String?) async {
        guard let item = currentItem, let id = try? sessionId() else { return }
        // Failures are swallowed. A student telling us something is wrong must
        // not then be told that telling us went wrong.
        try? await client.report(
            sessionId: id,
            ContentReport(
                itemId: item.id, targetKind: targetKind, targetId: targetId,
                reason: reason, text: text
            )
        )
    }

    func end() async {
        guard let id = try? sessionId() else { return }
        _ = try? await client.end(id)
        try? resumeStore.save(nil)
    }

    // MARK: Plumbing

    private func adopt(_ session: PracticeSession) {
        self.session = session
        hints = []
        analysis = nil
        clearEntry()
        shownAt = Date()
        phase = session.isFinished ? .finished(session) : .answering
    }

    private func sessionId() throws -> String {
        guard let id = session?.id else { throw APIError.unknown("No session.") }
        return id
    }

    /// Turns a failure into something the screen can say.
    ///
    /// `no_questions` is not an error: in review mode it means nothing is due,
    /// which is the outcome a student wants.
    private func failure(for error: any Error) -> Phase {
        switch PracticeRefusal(error) {
        case .noQuestions:
            return .nothingDue
        case .sessionNotActive, .wrongItem:
            // The app and the server disagree about where we are. The server is
            // right; start again rather than arguing.
            try? resumeStore.save(nil)
            return .failed(message: "問題がずれてしまいました。もう一度はじめてください。")
        case .learnerTokenRequired:
            return .failed(message: "この端末では練習を開けません。")
        default:
            let isOffline = (error as? APIError)?.isTransient == true
            return .failed(
                message: isOffline
                    ? "通信できませんでした。電波のよいところでもう一度ためしてください。"
                    : "問題を読み込めませんでした。もう一度ためしてください。"
            )
        }
    }
}
