import Foundation
import Testing
@testable import WakaRouteKit

private func id(_ value: String) -> ElementId { ElementId("sample-\(value)") }

@Suite("Study focus")
struct StudyFocusTests {

    private let subject = SampleUnderstandingMap.math

    @Test("An element whose prerequisites are solid is ready")
    func readyWhenPrerequisitesAreSolid() throws {
        let mastery = MasteryRecord(levels: [id("a1"): .solvesBasics])
        let focus = StudyFocus(subject: subject, mastery: mastery)

        let a2 = try #require(subject.elements.first { $0.id == id("a2") })
        #expect(focus.readiness(of: a2) == .ready)
    }

    @Test("An element with a weak prerequisite is blocked, naming what is missing")
    func blockedNamesTheMissingPrerequisite() throws {
        let mastery = MasteryRecord(levels: [id("a1"): .understandsMeaning])
        let focus = StudyFocus(subject: subject, mastery: mastery)

        let a2 = try #require(subject.elements.first { $0.id == id("a2") })
        #expect(focus.readiness(of: a2) == .blocked(missingPrerequisites: [id("a1")]))
    }

    /// The behaviour the whole product rests on: the student appears stuck on
    /// 一次関数, but the earliest thing actually blocking them is 文字を用いた式.
    @Test("Tracing back from a blocked element reaches the real cause, not the symptom")
    func tracesBackToRootCause() throws {
        let focus = StudyFocus(subject: subject, mastery: SampleUnderstandingMap.partwayMastery)

        let firstOrderFunction = try #require(subject.elements.first { $0.id == id("c2") })
        #expect(focus.readiness(of: firstOrderFunction) != .ready)

        let causes = focus.rootCauses(of: firstOrderFunction).map(\.id)
        #expect(causes == [id("a2")], "Should point at 文字を用いた式, not 一次関数 or 比例と反比例.")
    }

    @Test("A mastered element is never recommended")
    func masteredIsNotRecommended() {
        var mastery = MasteryRecord()
        for element in subject.elements { mastery[element.id] = .stableUnderTime }

        let focus = StudyFocus(subject: subject, mastery: mastery)
        #expect(focus.readyElements().isEmpty)
        #expect(focus.recommendations().isEmpty)
    }

    @Test("A blank slate recommends only elements with no prerequisites")
    func blankSlateStartsAtTheBeginning() {
        let focus = StudyFocus(subject: subject, mastery: MasteryRecord())

        for recommendation in focus.recommendations(limit: 10) {
            #expect(
                recommendation.element.prerequisiteIds.isEmpty,
                "\(recommendation.element.name) was suggested before its prerequisites."
            )
        }
    }

    /// The element holding up the most work comes first, even though other
    /// elements sit at a lower level. Ranking by level alone would bury the
    /// real blocker under everything the student simply has not reached yet.
    @Test("The element that unblocks the most is recommended first")
    func mostUnblockingFirst() throws {
        let focus = StudyFocus(subject: subject, mastery: SampleUnderstandingMap.partwayMastery)
        let top = try #require(focus.recommendations(limit: 3).first)

        #expect(top.element.id == id("a2"), "文字を用いた式 blocks the most, so it leads.")
        #expect(top.currentLevel == .understandsMeaning)
        #expect(top.unblocks.count > 1)
    }

    @Test("Ties are broken toward the weaker foundation")
    func tiesPreferWeakerFoundation() {
        let focus = StudyFocus(subject: subject, mastery: SampleUnderstandingMap.partwayMastery)
        let recommendations = focus.recommendations(limit: 5)

        for (earlier, later) in zip(recommendations, recommendations.dropFirst())
        where earlier.unblocks.count == later.unblocks.count {
            #expect(earlier.currentLevel <= later.currentLevel)
        }
    }

    @Test("Recommendations are capped and never duplicated")
    func recommendationsAreCappedAndUnique() {
        let focus = StudyFocus(subject: subject, mastery: SampleUnderstandingMap.partwayMastery)
        let recommendations = focus.recommendations(limit: 3)

        #expect(recommendations.count <= 3)
        #expect(Set(recommendations.map(\.id)).count == recommendations.count)
    }

    @Test("A cycle in the graph does not hang the walk")
    func cyclesTerminate() throws {
        let looped = Subject(
            id: SubjectId("loop"),
            name: "循環",
            domains: [LearningDomain(id: "A", code: "A", name: "A")],
            elements: [
                LearningElement(id: ElementId("x"), name: "X", domainId: "A", prerequisiteIds: [ElementId("y")]),
                LearningElement(id: ElementId("y"), name: "Y", domainId: "A", prerequisiteIds: [ElementId("x")])
            ]
        )
        let focus = StudyFocus(subject: looped, mastery: MasteryRecord())
        let x = try #require(looped.elements.first)

        #expect(focus.rootCauses(of: x).isEmpty)
    }
}

@Suite("Subject progress")
struct SubjectProgressTests {

    @Test("Counts add up against the element total")
    func countsAreConsistent() {
        let progress = SubjectProgress(
            subject: SampleUnderstandingMap.math,
            mastery: SampleUnderstandingMap.partwayMastery
        )

        #expect(progress.totalElements == SampleUnderstandingMap.math.elements.count)
        #expect(progress.notStartedCount + progress.inProgressCount + progress.masteredCount == progress.totalElements)
    }

    @Test("An empty subject reports zero rather than dividing by zero")
    func emptySubjectIsSafe() {
        let empty = Subject(id: SubjectId("e"), name: "国語", domains: [], elements: [])
        let progress = SubjectProgress(subject: empty, mastery: MasteryRecord())

        #expect(progress.totalElements == 0)
        #expect(progress.masteredFraction == 0)
    }
}
