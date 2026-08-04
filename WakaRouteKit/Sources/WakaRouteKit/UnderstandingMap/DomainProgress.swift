import Foundation

/// One 領域's state inside a subject — the level that answers "where am I
/// strong and where am I weak in 数学?".
public struct DomainProgress: Sendable, Equatable, Identifiable {
    public var id: String { domain.id }
    public let domain: LearningDomain
    public let totalElements: Int
    public let masteredCount: Int
    public let blockedCount: Int
    /// 要素 at 基本を解ける or better. See `SubjectProgress.solidCount` — the
    /// upper levels have no 確認テスト behind them yet, so this is the honest
    /// measure of how far a 領域 has come.
    public let solidCount: Int
    /// How many elements sit at each level, lowest first. Drives the stacked
    /// bar, which shows the shape of a 領域 rather than one averaged number.
    public let levelCounts: [(level: MasteryLevel, count: Int)]

    public init(domain: LearningDomain, subject: Subject, mastery: MasteryRecord) {
        let focus = StudyFocus(subject: subject, mastery: mastery)
        let elements = subject.elements(inDomain: domain.id)

        self.domain = domain
        totalElements = elements.count
        masteredCount = elements.filter { focus.readiness(of: $0) == .mastered }.count
        // Stumbles only — see `StudyFocus.isStumbling`. Counting everything a
        // student has not reached yet would mark 数と式 as 手前でつまずき for a
        // student who has finished one of its eight 要素 in order.
        blockedCount = elements.filter { focus.isStumbling($0) }.count
        solidCount = elements.filter { mastery[$0.id] >= MasteryLevel.prerequisiteThreshold }.count

        levelCounts = MasteryLevel.allCases.map { level in
            (level, elements.filter { mastery[$0.id] == level }.count)
        }
    }

    public var masteredFraction: Double {
        totalElements == 0 ? 0 : Double(masteredCount) / Double(totalElements)
    }

    public var solidFraction: Double {
        totalElements == 0 ? 0 : Double(solidCount) / Double(totalElements)
    }

    /// A plain-language read on the 領域, so the student is not left to
    /// interpret a bar on their own.
    public enum Standing: Sendable, Equatable {
        case notStarted
        case blocked      // Something earlier is in the way.
        case inProgress
        case strong
    }

    /// Note the order: a 領域 the student has not touched reads as これから even
    /// when its first 要素 is blocked by something in another 領域.
    ///
    /// 「つまずき」 means they tried and something earlier was missing. Saying it
    /// about work they have not begun is both false and discouraging, and a 中3
    /// student opening 関数 for the first time should not be told they have
    /// already failed at it.
    public var standing: Standing {
        guard totalElements > 0 else { return .notStarted }

        let untouched = levelCounts.first { $0.level == .notStarted }?.count ?? 0
        if untouched == totalElements { return .notStarted }

        if blockedCount > 0 { return .blocked }
        // Measured against 基本を解ける, not 習得. The upper levels need 確認テスト
        // that do not exist yet, so a threshold on `masteredFraction` would put
        // every 領域 at いま学習中 forever, however much the student had done.
        return solidFraction >= 0.6 ? .strong : .inProgress
    }

    public static func == (lhs: DomainProgress, rhs: DomainProgress) -> Bool {
        lhs.domain == rhs.domain
            && lhs.totalElements == rhs.totalElements
            && lhs.masteredCount == rhs.masteredCount
            && lhs.blockedCount == rhs.blockedCount
    }
}

extension Subject {
    /// Every 領域 with its progress, in map order (A, B, C, D).
    public func domainProgress(mastery: MasteryRecord) -> [DomainProgress] {
        domains.map { DomainProgress(domain: $0, subject: self, mastery: mastery) }
    }
}
