import Foundation

/// What a student thought of a lesson.
///
/// Two values rather than five stars. A 中学生 given a five-point scale answers
/// somewhere in the middle, the average never moves, and nobody learns which
/// lesson to rewrite. 「むずかしかった率」 does move, and it sorts the backlog.
public struct LessonFeedback: Codable, Sendable, Equatable {
    public enum Reason: String, Codable, Sendable, CaseIterable, Identifiable {
        case explanation
        case examples
        case questions
        case length

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .explanation: "説明が難しい"
            case .examples: "例が少ない"
            case .questions: "問題が難しい"
            case .length: "量が多い"
            }
        }
    }

    /// The server's cap on the free-text field (LMS-DEV t-d1bea84).
    ///
    /// Going over is a **400**, which this app treats as permanent and would
    /// therefore set the queued feedback aside and never send it. A student who
    /// wrote a long answer offline would lose all of it, silently. So the
    /// screen keeps them under the limit, and this clamps as a last resort:
    /// losing the tail of a sentence beats losing the whole answer.
    public static let commentLimit = 1000

    public let understood: Bool
    /// Only meaningful when `understood` is false — the server ignores it
    /// otherwise, and clears any stored reasons when an answer changes to
    /// 「わかった」.
    public let reasons: [Reason]
    /// Optional, and deliberately secondary — see `LessonFeedbackView`.
    public let comment: String?

    public init(understood: Bool, reasons: [Reason] = [], comment: String? = nil) {
        self.understood = understood
        // Sending reasons alongside 「わかった」 would be discarded anyway; not
        // sending them keeps the request honest about what was meant.
        self.reasons = understood ? [] : reasons
        self.comment = comment.map { String($0.prefix(Self.commentLimit)) }
    }

    private enum CodingKeys: String, CodingKey { case understood, reasons, comment }

    /// Field by field, and tolerant of a reason this build does not know —
    /// the server's list may grow before the app does, and one unfamiliar
    /// string must not throw away the rest of a student's answer.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        understood = try c.decodeIfPresent(Bool.self, forKey: .understood) ?? true
        reasons = (try c.decodeIfPresent([String].self, forKey: .reasons) ?? [])
            .compactMap(Reason.init(rawValue:))
        comment = try c.decodeIfPresent(String.self, forKey: .comment)
    }
}

extension ContentClient {

    /// Records what a student thought of a lesson.
    ///
    /// Contract confirmed and deployed — LMS-DEV t-d1bea84. Notes that matter
    /// here: `understood` is required (400 without it), the server keeps **one
    /// answer per lesson and overwrites**, and `Idempotency-Key` is honoured, so
    /// a replay from the offline queue is safe.
    public func submitFeedback(
        lessonId: String,
        feedback: LessonFeedback,
        idempotencyKey: String
    ) async throws {
        _ = try await postFeedback(
            lessonId: lessonId,
            body: try JSONEncoder().encode(feedback),
            idempotencyKey: idempotencyKey
        )
    }
}
