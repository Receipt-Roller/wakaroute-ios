import Foundation

/// What a student knows, keyed by 要素. Anything absent is `.notStarted`.
public struct MasteryRecord: Sendable, Codable, Equatable {
    private var levels: [ElementId: MasteryLevel]

    /// 要素 whose most recent quiz fell short.
    ///
    /// Kept apart from the level because 意味がわかる covers two quite different
    /// situations: a student partway through reading, and a student who sat the
    /// quiz and missed. **Only the second is a stumble**, and only the second
    /// may ever be reported as one — otherwise every student working through a
    /// subject in order is told they are stuck.
    public private(set) var struggling: Set<ElementId>

    public init(levels: [ElementId: MasteryLevel] = [:], struggling: Set<ElementId> = []) {
        self.levels = levels
        self.struggling = struggling
    }

    public subscript(id: ElementId) -> MasteryLevel {
        get { levels[id] ?? .notStarted }
        set { levels[id] = newValue }
    }

    public mutating func markStruggling(_ id: ElementId) {
        struggling.insert(id)
    }
}

/// Why a 要素 is or is not something to work on now.
public enum ElementReadiness: Sendable, Equatable {
    /// Already at or above the mastery threshold.
    case mastered
    /// Every prerequisite is solid, so this can be studied now.
    case ready
    /// One or more prerequisites are not solid yet. Studying this now would
    /// mean building on something the student cannot actually use.
    case blocked(missingPrerequisites: [ElementId])
}

/// A concrete thing to do next, with the reason attached.
public struct StudyRecommendation: Sendable, Equatable, Identifiable {
    public var id: ElementId { element.id }
    public let element: LearningElement
    public let currentLevel: MasteryLevel
    /// The 要素 this one is holding up, when the recommendation came from
    /// tracing backwards. Empty when it is simply the natural next step.
    public let unblocks: [LearningElement]
    /// The quiz here was sat and missed.
    ///
    /// Separate from the level so a screen can tell "something went wrong" from
    /// "still working through it" — they look identical at 意味がわかる, and only
    /// the first should be drawn as a problem.
    public let isStruggling: Bool

    public init(
        element: LearningElement,
        currentLevel: MasteryLevel,
        unblocks: [LearningElement] = [],
        isStruggling: Bool = false
    ) {
        self.element = element
        self.currentLevel = currentLevel
        self.unblocks = unblocks
        self.isStruggling = isStruggling
    }

    /// The single ordering rule for "what to work on first", used both within a
    /// subject and when merging subjects on the home screen.
    ///
    /// Kept here rather than at each call site because applying it in one place
    /// and a level-only sort in another silently reverses the result.
    public static func isMoreUrgent(_ a: StudyRecommendation, _ b: StudyRecommendation) -> Bool {
        if a.unblocks.count != b.unblocks.count { return a.unblocks.count > b.unblocks.count }
        if a.currentLevel != b.currentLevel { return a.currentLevel < b.currentLevel }
        return a.element.id.rawValue < b.element.id.rawValue
    }
}

/// Reads the prerequisite graph against what a student knows.
///
/// This is the product's core idea in one type: rather than reporting "weak at
/// functions", it finds the earliest 要素 that is actually blocking progress
/// and points there.
public struct StudyFocus: Sendable {
    private let subject: Subject
    private let mastery: MasteryRecord
    private let elementsById: [ElementId: LearningElement]

    public init(subject: Subject, mastery: MasteryRecord) {
        self.subject = subject
        self.mastery = mastery
        self.elementsById = Dictionary(
            subject.elements.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    public func level(of id: ElementId) -> MasteryLevel {
        mastery[id]
    }

    public func readiness(of element: LearningElement) -> ElementReadiness {
        if mastery[element.id] >= MasteryLevel.masteredThreshold {
            return .mastered
        }

        let missing = element.prerequisiteIds.filter {
            mastery[$0] < MasteryLevel.prerequisiteThreshold
        }
        return missing.isEmpty ? .ready : .blocked(missingPrerequisites: missing)
    }

    /// Everything the student could legitimately work on right now.
    public func readyElements() -> [LearningElement] {
        subject.elements.filter { readiness(of: $0) == .ready }
    }

    /// Whether this 要素 is held up by something that actually went wrong.
    ///
    /// Being blocked is the ordinary condition of everything a student has not
    /// reached yet — on a first launch, every 要素 but three is blocked. Calling
    /// that 「手前でつまずき」 would light the warning on every 領域 for every
    /// student, permanently, and mean nothing.
    ///
    /// A stumble needs evidence: a prerequisite whose quiz was sat and missed.
    public func isStumbling(_ element: LearningElement) -> Bool {
        guard case let .blocked(missing) = readiness(of: element) else { return false }
        return missing.contains { mastery.struggling.contains($0) }
    }

    /// Walks backwards from a 要素 the student cannot yet do, to the earliest
    /// unmet prerequisites that *are* ready — the actual place to restart.
    ///
    /// This is 「つまずきの前提まで戻る」. Telling a student stuck on 一次関数 to
    /// practise 一次関数 is useless if the real gap is 文字を用いた式.
    public func rootCauses(of element: LearningElement) -> [LearningElement] {
        var found: [LearningElement] = []
        var seen: Set<ElementId> = []

        func walk(_ current: LearningElement) {
            guard seen.insert(current.id).inserted else { return }  // guards against cycles

            switch readiness(of: current) {
            case .mastered:
                return
            case .ready:
                found.append(current)
            case let .blocked(missing):
                for id in missing {
                    guard let prerequisite = elementsById[id] else { continue }
                    walk(prerequisite)
                }
            }
        }

        walk(element)
        return found
    }

    /// What to put in front of the student.
    ///
    /// Ranked by how much each 要素 unblocks, not by how little the student has
    /// done. Sorting by level alone would push every untouched 要素 above the
    /// one actually holding the subject up — which is precisely the "study the
    /// symptom" behaviour this map exists to avoid. Ties break toward the
    /// weaker foundation.
    public func recommendations(limit: Int = 3) -> [StudyRecommendation] {
        var blockedBy: [ElementId: [LearningElement]] = [:]

        // Every blocked 要素 votes for the earliest prerequisite really at fault.
        for element in subject.elements {
            guard case .blocked = readiness(of: element) else { continue }
            for cause in rootCauses(of: element) {
                blockedBy[cause.id, default: []].append(element)
            }
        }

        var results = blockedBy.compactMap { id, blocked -> StudyRecommendation? in
            guard let element = elementsById[id] else { return nil }
            return StudyRecommendation(
                element: element,
                currentLevel: mastery[id],
                unblocks: blocked,
                isStruggling: mastery.struggling.contains(id)
            )
        }

        // Then anything with nothing in its way, for a student who is not stuck.
        let alreadyListed = Set(results.map(\.id))
        results += readyElements()
            .filter { !alreadyListed.contains($0.id) }
            .map {
                StudyRecommendation(
                    element: $0,
                    currentLevel: mastery[$0.id],
                    isStruggling: mastery.struggling.contains($0.id)
                )
            }

        return Array(results.sorted(by: StudyRecommendation.isMoreUrgent).prefix(limit))
    }
}

/// One subject's state, for the five-across view on the home screen.
public struct SubjectProgress: Sendable, Equatable, Identifiable {
    public var id: SubjectId { subjectId }
    public let subjectId: SubjectId
    public let subjectName: String
    public let totalElements: Int
    public let masteredCount: Int
    public let inProgressCount: Int
    public let notStartedCount: Int
    public let blockedCount: Int
    /// 要素 at 基本を解ける or better — solid enough that what builds on them can
    /// be studied. This, not `masteredCount`, is the number worth showing while
    /// the upper levels have no 確認テスト behind them: nothing can reach
    /// 習得 today, and a ring reading 0/26 for a student who has finished the
    /// subject would be false in the other direction.
    public let solidCount: Int

    /// Present only because a bar has to be some length. The levels are the
    /// truth; this is not shown as a headline number.
    public var masteredFraction: Double {
        totalElements == 0 ? 0 : Double(masteredCount) / Double(totalElements)
    }

    public init(subject: Subject, mastery: MasteryRecord) {
        let focus = StudyFocus(subject: subject, mastery: mastery)
        subjectId = subject.id
        subjectName = subject.name
        totalElements = subject.elements.count

        var mastered = 0, inProgress = 0, notStarted = 0, blocked = 0, solid = 0
        for element in subject.elements {
            switch focus.readiness(of: element) {
            case .mastered: mastered += 1
            // Only a stumble counts. Everything not yet reached is blocked too,
            // and reporting that as 手前でつまずき would flag every subject a
            // student has begun.
            case .blocked: if focus.isStumbling(element) { blocked += 1 }
            case .ready: break
            }
            let level = mastery[element.id]
            if level == .notStarted {
                notStarted += 1
            } else if level < MasteryLevel.masteredThreshold {
                inProgress += 1
            }
            if level >= MasteryLevel.prerequisiteThreshold { solid += 1 }
        }

        masteredCount = mastered
        inProgressCount = inProgress
        notStartedCount = notStarted
        blockedCount = blocked
        solidCount = solid
    }

    public var solidFraction: Double {
        totalElements == 0 ? 0 : Double(solidCount) / Double(totalElements)
    }
}
