import Foundation

/// Anything that can be put on a card and ordered.
public protocol StudyCard: Identifiable, Sendable, Equatable where ID == String {
    var id: String { get }
    /// 1–3, or nil for the 小学校 review words.
    var recommendedGrade: Int? { get }
    /// Lower is commoner.
    var frequencyRank: Int? { get }
    var sequence: Int? { get }
    /// `elementary-review` or `junior-high`.
    var studyStage: String? { get }
    /// False when the card has no back — nothing to be tested on.
    var isStudiable: Bool { get }
}

extension WordCard: StudyCard {
    public var studyStage: String? { stage }

    /// Seven of the 2,450 published words carry no Japanese meaning, `i` and
    /// `email` among them. A card whose back is blank cannot be studied, so it
    /// is left out rather than shown empty. Reported as a content bug.
    public var isStudiable: Bool { !meaningsJa.isEmpty }
}

extension KanjiCard: StudyCard {
    public var studyStage: String? { officialStage }

    public var isStudiable: Bool { !onReadings.isEmpty || !kunReadings.isEmpty }
}

/// How well one card is known, and when it is next worth showing.
///
/// `box` is a count of consecutive correct answers, not a score. It is reset by
/// a wrong answer because **one correct answer is not knowing something** — the
/// same mistake this app already made once by unlocking a whole 要素 from a
/// single right question.
public struct CardReview: Codable, Sendable, Equatable {
    public static let learnedBox = 5

    public var box: Int
    /// The day the card was last answered, at midnight.
    public var reviewedOn: Date

    public init(box: Int, reviewedOn: Date) {
        self.box = box
        self.reviewedOn = reviewedOn
    }

    public var isLearned: Bool { box >= Self.learnedBox }
}

/// Which cards the student has seen. Lives only on this device.
///
/// **Card progress is not carried across a handset change.** `/me/link` moves
/// study history and target schools; it does not know about cards, and there is
/// no server to put them on. The screen has to say so — losing work silently is
/// worse than not carrying it.
public struct CardProgress: Codable, Sendable, Equatable {
    private var reviews: [String: CardReview]

    public init(reviews: [String: CardReview] = [:]) {
        self.reviews = reviews
    }

    public subscript(cardId: String) -> CardReview? { reviews[cardId] }

    public var learnedCount: Int { reviews.values.count(where: \.isLearned) }
    public var startedCount: Int { reviews.count }

    public mutating func record(_ review: CardReview, for cardId: String) {
        reviews[cardId] = review
    }
}

/// Spaced repetition, deliberately small.
///
/// A correct answer moves the card one box up and pushes it further away; a
/// wrong answer sends it back to the start. Five consecutive correct answers
/// retire it.
public enum CardScheduler {

    /// Days to wait after reaching each box. Index 0 is unused — a card in
    /// box 0 has not been answered correctly yet and is always due.
    public static let intervalsInDays = [0, 1, 3, 7, 16, 35]

    public static func interval(forBox box: Int) -> Int {
        intervalsInDays[min(max(box, 0), intervalsInDays.count - 1)]
    }

    /// The state after answering a card.
    public static func answering(
        _ review: CardReview?,
        correct: Bool,
        on day: Date,
        calendar: Calendar = .current
    ) -> CardReview {
        let today = calendar.startOfDay(for: day)
        guard correct else { return CardReview(box: 0, reviewedOn: today) }
        return CardReview(box: min((review?.box ?? 0) + 1, CardReview.learnedBox), reviewedOn: today)
    }

    /// Whether a card should be shown today.
    ///
    /// A review dated in the future means the clock moved backwards — a real
    /// thing on a handset whose time was wrong and then corrected. The card is
    /// shown rather than hidden until the date catches up, which could be
    /// years.
    public static func isDue(
        _ review: CardReview?,
        on day: Date,
        calendar: Calendar = .current
    ) -> Bool {
        guard let review else { return true }
        if review.isLearned { return false }

        let today = calendar.startOfDay(for: day)
        let reviewed = calendar.startOfDay(for: review.reviewedOn)
        if reviewed > today { return true }

        let waited = calendar.dateComponents([.day], from: reviewed, to: today).day ?? 0
        return waited >= interval(forBox: review.box)
    }
}

/// Picks which cards to show, and in what order.
public enum CardDeck {

    /// The range a student is working on.
    public struct Scope: Sendable, Equatable {
        /// Nil means every year.
        public var grade: Int?
        /// Nil means both 小学校の復習 and 中学.
        public var stage: String?

        public init(grade: Int? = nil, stage: String? = nil) {
            self.grade = grade
            self.stage = stage
        }
    }

    /// How many cards one sitting holds. A deck a student cannot finish is a
    /// punishment, the same way a broken 連続日数 is.
    public static let sessionSize = 20

    /// Cards in the scope, commonest first.
    ///
    /// Ordering is by `frequencyRank` because that is what makes the early
    /// cards worth learning. `sequence` only breaks ties, and cards with no
    /// rank go last rather than first — an unranked card sorted as rank 0
    /// would jump the whole deck.
    public static func inScope<Card: StudyCard>(_ cards: [Card], scope: Scope) -> [Card] {
        cards
            .filter { card in
                guard card.isStudiable else { return false }
                if let grade = scope.grade, card.recommendedGrade != grade { return false }
                if let stage = scope.stage, card.studyStage != stage { return false }
                return true
            }
            .sorted { first, second in
                let left = (first.frequencyRank ?? Int.max, first.sequence ?? Int.max, first.id)
                let right = (second.frequencyRank ?? Int.max, second.sequence ?? Int.max, second.id)
                return left < right
            }
    }

    /// One sitting: everything already started and due, then new cards to fill.
    ///
    /// Due cards come first so that a student who has been away is not handed
    /// new material on top of a backlog.
    public static func session<Card: StudyCard>(
        from cards: [Card],
        scope: Scope,
        progress: CardProgress,
        on day: Date,
        size: Int = sessionSize,
        calendar: Calendar = .current
    ) -> [Card] {
        let ordered = inScope(cards, scope: scope)

        let due = ordered.filter { card in
            progress[card.id] != nil && CardScheduler.isDue(progress[card.id], on: day, calendar: calendar)
        }
        let fresh = ordered.filter { progress[$0.id] == nil }

        return Array((due + fresh).prefix(size))
    }
}
