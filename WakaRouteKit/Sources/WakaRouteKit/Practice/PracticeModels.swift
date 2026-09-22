import Foundation

// MARK: - Open vocabularies
//
// Every one of these is a `RawRepresentable` struct rather than an enum, as
// 受験コーチ API 契約 v1 §3 requires: adding a value is a non-breaking change
// the server may make at any time, and an unknown one must be drawn as その他
// rather than failing the decode and taking the whole session down mid-question.

public struct SessionStatus: Hashable, Sendable, Codable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public static let active = SessionStatus("active")
    public static let completed = SessionStatus("completed")
    public static let abandoned = SessionStatus("abandoned")
    public static let expired = SessionStatus("expired")

    /// Whether more questions can still be answered.
    public var isActive: Bool { self == .active }
}

/// Why the session stopped. `nil` while it is still running.
public struct SessionEndReason: Hashable, Sendable, Codable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public static let limit = SessionEndReason("limit")
    public static let time = SessionEndReason("time")
    public static let mastered = SessionEndReason("mastered")
    public static let exhausted = SessionEndReason("exhausted")
    public static let abandoned = SessionEndReason("abandoned")
}

public struct QuestionKind: Hashable, Sendable, Codable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    /// Pick one of the options.
    public static let single = QuestionKind("single")
    /// Type a number.
    public static let numeric = QuestionKind("numeric")
    /// Type an answer.
    public static let text = QuestionKind("text")
}

/// How a question was closed.
///
/// **Only `firstTry` and `self` count as reaching it unaided**, and only those
/// two move mastery. That distinction is the whole point of the hint ladder:
/// a student who gets there after two hints has got there, and the record says
/// how.
public struct AnswerOutcome: Hashable, Sendable, Codable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public static let firstTry = AnswerOutcome("first-try")
    /// Right on a later attempt, without help.
    public static let selfReached = AnswerOutcome("self")
    /// Right, after hints.
    public static let assisted = AnswerOutcome("assisted")
    /// The student asked to see the answer.
    public static let revealed = AnswerOutcome("revealed")
    /// Attempts ran out.
    public static let failed = AnswerOutcome("failed")

    public var reachedUnaided: Bool { self == .firstTry || self == .selfReached }
}

/// One rung of the hint ladder, in the order the server gives them.
public struct HintTier: Hashable, Sendable, Codable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    /// What the question is asking.
    public static let intent = HintTier("intent")
    /// A small nudge.
    public static let small = HintTier("small")
    /// The thing underneath that may be missing.
    public static let prerequisite = HintTier("prerequisite")
    /// The same question, said differently.
    public static let rephrase = HintTier("rephrase")
    /// A worked question with different numbers — never this one's answer.
    public static let similar = HintTier("similar")

    public var displayName: String {
        switch self {
        case .intent: "何を聞かれているか"
        case .small: "小さなヒント"
        case .prerequisite: "ひとつ手前にもどる"
        case .rephrase: "言いかえてみる"
        case .similar: "似た問題を見る"
        default: "ヒント"
        }
    }
}

public struct AnalysisCategory: Hashable, Sendable, Codable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public static let careless = AnalysisCategory("careless")
    public static let misconception = AnalysisCategory("misconception")
    public static let prerequisiteGap = AnalysisCategory("prerequisite-gap")
    public static let misread = AnalysisCategory("misread")
    public static let unknown = AnalysisCategory("unknown")

    public var displayName: String {
        switch self {
        case .careless: "うっかりミス"
        case .misconception: "考え方のずれ"
        case .prerequisiteGap: "ひとつ手前が足りていない"
        case .misread: "問題の読み違い"
        default: "はっきりしない"
        }
    }
}

// MARK: - The question

public struct QuestionOption: Sendable, Codable, Equatable, Identifiable {
    public let key: String
    public let text: String

    public var id: String { key }
}

/// A question as rendered for this student, with these numbers.
///
/// **It never carries the answer.** Marking is the server's, always — §6.1 of
/// the start guide — and the answer only comes back once the question is
/// closed. Nothing here should ever be asked to decide whether a student is
/// right.
public struct RenderedQuestion: Sendable, Decodable, Equatable {
    public let questionId: String
    public let version: Int?
    /// What the numbers were drawn from. The same seed renders the same
    /// question, which is how a session survives the app being killed.
    public let seed: Int?
    public let kind: QuestionKind
    public let stem: String
    public let options: [QuestionOption]
    public let variables: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case questionId, version, seed, kind, stem, options, variables
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        questionId = try c.decodeIfPresent(String.self, forKey: .questionId) ?? ""
        version = try c.decodeIfPresent(FlexibleInt.self, forKey: .version)?.value
        seed = try c.decodeIfPresent(FlexibleInt.self, forKey: .seed)?.value
        kind = try c.decodeIfPresent(QuestionKind.self, forKey: .kind) ?? .text
        stem = try c.decodeIfPresent(String.self, forKey: .stem) ?? ""
        options = try c.decodeIfPresent([QuestionOption].self, forKey: .options) ?? []
        // The server sends whatever the template used — numbers, strings.
        // Only ever shown, never computed with, so the loose form is fine.
        variables = try c.decodeIfPresent([String: FlexibleString].self, forKey: .variables)?
            .mapValues(\.value)
    }

    public init(
        questionId: String, version: Int? = nil, seed: Int? = nil,
        kind: QuestionKind, stem: String, options: [QuestionOption] = [],
        variables: [String: String]? = nil
    ) {
        self.questionId = questionId
        self.version = version
        self.seed = seed
        self.kind = kind
        self.stem = stem
        self.options = options
        self.variables = variables
    }
}

/// The question currently on screen.
public struct PracticeItem: Sendable, Decodable, Equatable, Identifiable {
    public let id: String
    public let ordinal: Int
    public let conceptCode: String?
    public let difficulty: Int?
    public let attemptCount: Int
    public let attemptsLeft: Int
    public let hintsUsed: Int
    /// The rungs already climbed, in order.
    public let hintsGiven: [HintTier]
    public let canHint: Bool
    public let question: RenderedQuestion

    private enum CodingKeys: String, CodingKey {
        case id, ordinal, conceptCode, difficulty, attemptCount, attemptsLeft
        case hintsUsed, hintsGiven, canHint, question
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        ordinal = try c.decodeIfPresent(FlexibleInt.self, forKey: .ordinal)?.value ?? 0
        conceptCode = try c.decodeIfPresent(String.self, forKey: .conceptCode)
        difficulty = try c.decodeIfPresent(FlexibleInt.self, forKey: .difficulty)?.value
        attemptCount = try c.decodeIfPresent(FlexibleInt.self, forKey: .attemptCount)?.value ?? 0
        attemptsLeft = try c.decodeIfPresent(FlexibleInt.self, forKey: .attemptsLeft)?.value ?? 0
        hintsUsed = try c.decodeIfPresent(FlexibleInt.self, forKey: .hintsUsed)?.value ?? 0
        hintsGiven = try c.decodeIfPresent([HintTier].self, forKey: .hintsGiven) ?? []
        canHint = try c.decodeIfPresent(Bool.self, forKey: .canHint) ?? false
        question = try c.decode(RenderedQuestion.self, forKey: .question)
    }
}

/// One 理解要素 this session is working on, and how it is going.
public struct PracticeTarget: Sendable, Decodable, Equatable, Identifiable {
    public let conceptId: String
    public let code: String
    public let name: String
    public let attempts: Int
    public let correct: Int
    /// The model's estimate, 0–1. **An estimate** — never stated as fact.
    public let estimate: Double?
    public let mastered: Bool
    /// True when this is not what the student chose, but something underneath
    /// it that the session dropped back to.
    public let isPrerequisite: Bool

    public var id: String { conceptId }

    private enum CodingKeys: String, CodingKey {
        case conceptId, code, name, attempts, correct, estimate, mastered, isPrerequisite
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conceptId = try c.decodeIfPresent(String.self, forKey: .conceptId) ?? ""
        code = try c.decodeIfPresent(String.self, forKey: .code) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        attempts = try c.decodeIfPresent(FlexibleInt.self, forKey: .attempts)?.value ?? 0
        correct = try c.decodeIfPresent(FlexibleInt.self, forKey: .correct)?.value ?? 0
        estimate = try c.decodeIfPresent(Double.self, forKey: .estimate)
        mastered = try c.decodeIfPresent(Bool.self, forKey: .mastered) ?? false
        isPrerequisite = try c.decodeIfPresent(Bool.self, forKey: .isPrerequisite) ?? false
    }
}

/// The whole session, as the server sees it.
///
/// This is the only truth about where the student is. The app does not keep a
/// parallel copy of the question, the attempt count or the score — §6.3: on
/// resume, believe `current`, not anything cached.
public struct PracticeSession: Sendable, Decodable, Equatable, Identifiable {
    public let id: String
    public let status: SessionStatus
    public let endReason: SessionEndReason?
    public let remainingSeconds: Int?
    public let itemCount: Int
    public let answeredCount: Int
    public let correctCount: Int
    public let allowHints: Bool
    public let maxAttempts: Int
    public let targets: [PracticeTarget]
    /// The question being asked. `nil` once the session has ended.
    public let current: PracticeItem?

    private enum CodingKeys: String, CodingKey {
        case id, status, endReason, remainingSeconds, itemCount, answeredCount
        case correctCount, allowHints, maxAttempts, targets, current
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        status = try c.decodeIfPresent(SessionStatus.self, forKey: .status) ?? .active
        endReason = try c.decodeIfPresent(SessionEndReason.self, forKey: .endReason)
        remainingSeconds = try c.decodeIfPresent(FlexibleInt.self, forKey: .remainingSeconds)?.value
        itemCount = try c.decodeIfPresent(FlexibleInt.self, forKey: .itemCount)?.value ?? 0
        answeredCount = try c.decodeIfPresent(FlexibleInt.self, forKey: .answeredCount)?.value ?? 0
        correctCount = try c.decodeIfPresent(FlexibleInt.self, forKey: .correctCount)?.value ?? 0
        allowHints = try c.decodeIfPresent(Bool.self, forKey: .allowHints) ?? true
        maxAttempts = try c.decodeIfPresent(FlexibleInt.self, forKey: .maxAttempts)?.value ?? 1
        targets = try c.decodeIfPresent([PracticeTarget].self, forKey: .targets) ?? []
        current = try c.decodeIfPresent(PracticeItem.self, forKey: .current)
    }

    public var isFinished: Bool { !status.isActive || current == nil }
}

// MARK: - Answering

/// What the student typed or chose.
public enum PracticeAnswer: Sendable, Equatable, Encodable {
    /// One of the offered options.
    case option(key: String)
    /// Typed — a number or a phrase. Sent as written; the server marks it.
    case written(String)

    private enum CodingKeys: String, CodingKey { case key, text }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .option(key): try container.encode(key, forKey: .key)
        case let .written(text): try container.encode(text, forKey: .text)
        }
    }

    public var isEmpty: Bool {
        switch self {
        case let .option(key): key.isEmpty
        case let .written(text): text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

public struct AnswerResult: Sendable, Decodable, Equatable {
    public let isCorrect: Bool
    /// The misconception code this wrong answer matched, when it matched one.
    public let misconception: String?
    public let canRetry: Bool
    public let attemptsLeft: Int
    public let outcome: AnswerOutcome?
    /// Only present once the question is closed — never while it can still be
    /// retried.
    public let correctAnswerText: String?
    public let explanation: String?
    public let session: PracticeSession

    private enum CodingKeys: String, CodingKey {
        case isCorrect, misconception, canRetry, attemptsLeft, outcome
        case correctAnswerText, explanation, session
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isCorrect = try c.decodeIfPresent(Bool.self, forKey: .isCorrect) ?? false
        misconception = try c.decodeIfPresent(String.self, forKey: .misconception)
        canRetry = try c.decodeIfPresent(Bool.self, forKey: .canRetry) ?? false
        attemptsLeft = try c.decodeIfPresent(FlexibleInt.self, forKey: .attemptsLeft)?.value ?? 0
        outcome = try c.decodeIfPresent(AnswerOutcome.self, forKey: .outcome)
        correctAnswerText = try c.decodeIfPresent(String.self, forKey: .correctAnswerText)
        explanation = try c.decodeIfPresent(String.self, forKey: .explanation)
        session = try c.decode(PracticeSession.self, forKey: .session)
    }
}

// MARK: - Help

public struct PracticeHint: Sendable, Decodable, Equatable {
    public let tier: HintTier
    public let step: Int
    public let text: String
    /// True when the server had no authored hint at this rung and built one
    /// from the concept. Worth knowing; not worth showing.
    public let isFallback: Bool
    public let prerequisiteConceptCode: String?
    /// A worked question with different numbers. **Not this question's
    /// answer** — it comes with its own answer, which is the point.
    public let similarQuestion: SimilarQuestion?
    /// The rungs still available after this one.
    public let remaining: [HintTier]

    private enum CodingKeys: String, CodingKey {
        case tier, step, text, isFallback, prerequisiteConceptCode, similarQuestion, remaining
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tier = try c.decodeIfPresent(HintTier.self, forKey: .tier) ?? .small
        step = try c.decodeIfPresent(FlexibleInt.self, forKey: .step)?.value ?? 0
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        isFallback = try c.decodeIfPresent(Bool.self, forKey: .isFallback) ?? false
        prerequisiteConceptCode = try c.decodeIfPresent(String.self, forKey: .prerequisiteConceptCode)
        similarQuestion = try c.decodeIfPresent(SimilarQuestion.self, forKey: .similarQuestion)
        remaining = try c.decodeIfPresent([HintTier].self, forKey: .remaining) ?? []
    }
}

/// A different question on the same idea, shown worked through.
public struct SimilarQuestion: Sendable, Decodable, Equatable {
    public let stem: String
    public let options: [QuestionOption]
    public let correctAnswerText: String?
    public let explanation: String?

    private enum CodingKeys: String, CodingKey {
        case stem, options, correctAnswerText, explanation, kind, questionId
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stem = try c.decodeIfPresent(String.self, forKey: .stem) ?? ""
        options = try c.decodeIfPresent([QuestionOption].self, forKey: .options) ?? []
        correctAnswerText = try c.decodeIfPresent(String.self, forKey: .correctAnswerText)
        explanation = try c.decodeIfPresent(String.self, forKey: .explanation)
    }
}

public struct RevealedAnswer: Sendable, Decodable, Equatable {
    public let correctAnswerText: String?
    public let explanation: String?
    public let session: PracticeSession
}

/// Why the answer went wrong, as far as anything can tell.
public struct AnswerAnalysis: Sendable, Decodable, Equatable {
    public let category: AnalysisCategory
    /// 0–1. **Below 0.5 means "not sure"** and the start guide says to treat it
    /// as そうではなく「わからない」 — so the screen says so rather than
    /// asserting a cause.
    public let confidence: Double
    public let misconception: String?
    public let misconceptionDescription: String?
    public let prerequisiteConceptCode: String?
    public let evidence: [String]
    public let suggestion: String?
    /// Always the question bank's answer. The AI never decides it.
    public let correctAnswerText: String?
    /// `rule`, `rule+ai`, or `rule (ai failed)`.
    public let source: String?

    /// The line below which this is a guess rather than a finding.
    public static let confidenceFloor = 0.5

    public var isConfident: Bool { confidence >= Self.confidenceFloor }

    private enum CodingKeys: String, CodingKey {
        case category, confidence, misconception, misconceptionDescription
        case prerequisiteConceptCode, evidence, suggestion, correctAnswerText, source
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        category = try c.decodeIfPresent(AnalysisCategory.self, forKey: .category) ?? .unknown
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
        misconception = try c.decodeIfPresent(String.self, forKey: .misconception)
        misconceptionDescription = try c.decodeIfPresent(String.self, forKey: .misconceptionDescription)
        prerequisiteConceptCode = try c.decodeIfPresent(String.self, forKey: .prerequisiteConceptCode)
        evidence = try c.decodeIfPresent([String].self, forKey: .evidence) ?? []
        suggestion = try c.decodeIfPresent(String.self, forKey: .suggestion)
        correctAnswerText = try c.decodeIfPresent(String.self, forKey: .correctAnswerText)
        source = try c.decodeIfPresent(String.self, forKey: .source)
    }
}

/// Decodes a JSON scalar of whatever type into a string, for values that are
/// only ever displayed. The question templates use both numbers and strings.
struct FlexibleString: Decodable {
    let value: String

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let text = try? c.decode(String.self) { value = text }
        else if let number = try? c.decode(Int.self) { value = String(number) }
        else if let number = try? c.decode(Double.self) { value = String(number) }
        else if let flag = try? c.decode(Bool.self) { value = String(flag) }
        else { value = "" }
    }
}
