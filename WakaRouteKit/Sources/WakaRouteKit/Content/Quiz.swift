import Foundation

/// A lesson's 確認クイズ, embedded in `LessonDetail`.
public struct LessonQuiz: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String?
    public let instructions: String?
    public let passingScorePercent: Int
    public let isRequired: Bool
    public let questions: [QuizQuestion]

    private enum CodingKeys: String, CodingKey {
        case id, title, instructions, passingScorePercent, isRequired, questions
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions)
        passingScorePercent = try c.decodeIfPresent(FlexibleInt.self, forKey: .passingScorePercent)?.value ?? 0
        isRequired = try c.decodeIfPresent(Bool.self, forKey: .isRequired) ?? false
        questions = (try c.decodeIfPresent([QuizQuestion].self, forKey: .questions) ?? [])
            .sorted { $0.orderIndex < $1.orderIndex }
    }
}

public struct QuizQuestion: Decodable, Sendable, Equatable, Identifiable {
    /// Only the kinds the app can actually present. Anything else is skipped
    /// rather than rendered as an unanswerable question.
    public enum Kind: String, Sendable {
        case multipleChoiceSingle = "MultipleChoiceSingle"
        case multipleChoiceMultiple = "MultipleChoiceMultiple"
        case freeText = "FreeText"
        case unsupported

        init(raw: String?) {
            self = Kind(rawValue: raw ?? "") ?? .unsupported
        }
    }

    public let id: String
    public let questionText: String
    public let imageUrl: String?
    public let kind: Kind
    public let orderIndex: Int
    public let options: [QuizOption]

    private enum CodingKeys: String, CodingKey {
        case id, questionText, imageUrl, questionType, orderIndex, options
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        questionText = try c.decodeIfPresent(String.self, forKey: .questionText) ?? ""
        imageUrl = try c.decodeIfPresent(String.self, forKey: .imageUrl)
        kind = Kind(raw: try c.decodeIfPresent(String.self, forKey: .questionType))
        orderIndex = try c.decodeIfPresent(FlexibleInt.self, forKey: .orderIndex)?.value ?? 0
        // Deliberately **not** sorted by orderIndex.
        //
        // The server is to shuffle the options on every request (LMS-DEV
        // t-d1bea79) so a student cannot learn the answer's position. If it
        // shuffles the array but leaves orderIndex as authored, sorting here
        // would put them straight back and silently undo the whole thing.
        // Rendering in the order received works whichever way it is done.
        options = try c.decodeIfPresent([QuizOption].self, forKey: .options) ?? []
    }

    public var isAnswerable: Bool {
        switch kind {
        case .multipleChoiceSingle, .multipleChoiceMultiple: !options.isEmpty
        case .freeText: true
        case .unsupported: false
        }
    }
}

/// One choice.
///
/// Note the field is `text`, not the `optionText` used by the separate 確認テスト
/// endpoints — the two are different shapes despite looking alike.
public struct QuizOption: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let text: String
    public let orderIndex: Int

    private enum CodingKeys: String, CodingKey { case id, text, orderIndex }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        orderIndex = try c.decodeIfPresent(FlexibleInt.self, forKey: .orderIndex)?.value ?? 0
    }
}

public struct QuizAnswer: Sendable, Equatable, Encodable {
    public let questionId: String
    public let optionId: String?
    public let textAnswer: String?

    public init(questionId: String, optionId: String? = nil, textAnswer: String? = nil) {
        self.questionId = questionId
        self.optionId = optionId
        self.textAnswer = textAnswer
    }
}

public struct QuizResult: Decodable, Sendable, Equatable {
    public let attemptId: String
    public let quizId: String
    public let scorePercent: Int
    public let passingScorePercent: Int
    public let isPassed: Bool
    public let completedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case attemptId, quizId, scorePercent, passingScorePercent, isPassed, completedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        attemptId = try c.decode(String.self, forKey: .attemptId)
        quizId = try c.decode(String.self, forKey: .quizId)
        scorePercent = try c.decodeIfPresent(FlexibleInt.self, forKey: .scorePercent)?.value ?? 0
        passingScorePercent = try c.decodeIfPresent(FlexibleInt.self, forKey: .passingScorePercent)?.value ?? 0
        isPassed = try c.decodeIfPresent(Bool.self, forKey: .isPassed) ?? false
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
    }
}
