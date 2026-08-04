import Foundation

/// How well a single 要素 is understood.
///
/// WakaRoute deliberately does not express this as a percentage. "80% done"
/// says nothing about whether a student can use the idea under exam conditions,
/// and it invites grinding for a number. These five levels are the ones shown
/// on the web 理解マップ, and they describe capability instead.
public enum MasteryLevel: Int, Codable, Sendable, CaseIterable, Comparable {
    case notStarted = 0
    /// 意味がわかる
    case understandsMeaning = 1
    /// 基本を解ける
    case solvesBasics = 2
    /// 根拠をつなげる
    case connectsReasoning = 3
    /// 初見で使える
    case appliesToNovel = 4
    /// 時間内に安定する
    case stableUnderTime = 5

    public static func < (lhs: MasteryLevel, rhs: MasteryLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// The point at which a 要素 is solid enough that the things built on top
    /// of it can be studied without the student silently falling back.
    public static let prerequisiteThreshold = MasteryLevel.solvesBasics

    /// The point at which a 要素 counts as finished for exam purposes.
    public static let masteredThreshold = MasteryLevel.appliesToNovel
}

public struct SubjectId: Hashable, Sendable, Codable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public struct ElementId: Hashable, Sendable, Codable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// A 領域 — the broad grouping inside a subject (数と式, 図形, 関数, データの活用).
public struct LearningDomain: Identifiable, Sendable, Codable, Equatable {
    public let id: String
    /// The letter shown on the web map (A–D).
    public let code: String
    public let name: String

    public init(id: String, code: String, name: String) {
        self.id = id
        self.code = code
        self.name = name
    }
}

/// A 要素 — one unit of understanding, and the thing mastery is tracked against.
///
/// `id` is the permanent key. The web map currently labels these by Japanese
/// name only; names must never be used as identifiers.
public struct LearningElement: Identifiable, Sendable, Codable, Equatable {
    public let id: ElementId
    public let name: String
    public let domainId: String
    /// 中1–中3, when this is normally taught. Nil when it spans grades.
    public let grade: Int?
    /// The 要素 that must be understood first. These edges are the whole point
    /// of the map: they are what lets us send a student backwards to the real
    /// cause instead of drilling the symptom.
    public let prerequisiteIds: [ElementId]

    public init(
        id: ElementId,
        name: String,
        domainId: String,
        grade: Int? = nil,
        prerequisiteIds: [ElementId] = []
    ) {
        self.id = id
        self.name = name
        self.domainId = domainId
        self.grade = grade
        self.prerequisiteIds = prerequisiteIds
    }
}

public struct Subject: Identifiable, Sendable, Codable, Equatable {
    public let id: SubjectId
    public let name: String
    public let domains: [LearningDomain]
    public let elements: [LearningElement]

    public init(id: SubjectId, name: String, domains: [LearningDomain], elements: [LearningElement]) {
        self.id = id
        self.name = name
        self.domains = domains
        self.elements = elements
    }

    public func domain(id: String) -> LearningDomain? {
        domains.first { $0.id == id }
    }

    public func elements(inDomain domainId: String) -> [LearningElement] {
        elements.filter { $0.domainId == domainId }
    }
}
