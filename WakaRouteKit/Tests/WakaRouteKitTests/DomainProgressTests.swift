import Foundation
import Testing
@testable import WakaRouteKit

private func id(_ value: String) -> ElementId { ElementId("sample-\(value)") }

@Suite("Domain progress")
struct DomainProgressTests {

    private let subject = SampleUnderstandingMap.math

    @Test("Every 領域 in the subject gets an entry, in map order")
    func coversEveryDomainInOrder() {
        let progress = subject.domainProgress(mastery: SampleUnderstandingMap.partwayMastery)

        #expect(progress.map(\.domain.code) == ["A", "B", "C", "D"])
        #expect(progress.reduce(0) { $0 + $1.totalElements } == subject.elements.count)
    }

    @Test("Level counts account for every element in the 領域")
    func levelCountsAreComplete() {
        for progress in subject.domainProgress(mastery: SampleUnderstandingMap.partwayMastery) {
            let counted = progress.levelCounts.reduce(0) { $0 + $1.count }
            #expect(counted == progress.totalElements, "\(progress.domain.name) lost elements in the distribution.")
        }
    }

    /// Once a student has started a 領域, a blocked element is the signal they
    /// need, even if other elements there are going well.
    @Test("A started 領域 with a blocked element reads as blocked")
    func blockedDominatesOnceStarted() throws {
        let progress = subject.domainProgress(mastery: SampleUnderstandingMap.partwayMastery)
        let numbers = try #require(progress.first { $0.domain.code == "A" })

        #expect(numbers.blockedCount > 0)
        #expect(numbers.standing == .blocked)
    }

    /// The counterpart rule: 関数 is entirely untouched, and its first 要素 is
    /// blocked by 文字を用いた式 over in 数と式. It must still read as これから —
    /// the student has not stumbled here, they have not arrived here.
    @Test("An untouched 領域 reads as これから even when its entry is blocked")
    func untouchedDomainIsNotCalledStumbling() throws {
        let progress = subject.domainProgress(mastery: SampleUnderstandingMap.partwayMastery)
        let functions = try #require(progress.first { $0.domain.code == "C" })

        let focus = StudyFocus(subject: subject, mastery: SampleUnderstandingMap.partwayMastery)
        let entry = try #require(subject.elements(inDomain: functions.domain.id).first)
        if case .blocked = focus.readiness(of: entry) {} else {
            Issue.record("Its entry really should be blocked, or this test proves nothing.")
        }

        #expect(functions.standing == .notStarted, "…but nothing there has been attempted.")
    }

    /// The one a real student hit first.
    ///
    /// Eight 要素 in 数と式, one of them finished, the rest untouched. Everything
    /// after the second is blocked — that is simply what "not reached yet"
    /// looks like. Reporting it as 手前でつまずき lights the warning on every
    /// 領域 of every student who has begun, permanently, and says nothing.
    @Test("Working through a 領域 in order is 学習中, not 手前でつまずき")
    func orderlyProgressIsNotAStumble() throws {
        var mastery = MasteryRecord()
        let numbers = try #require(subject.domains.first { $0.code == "A" })
        let elements = subject.elements(inDomain: numbers.id)
        // The first one done, nothing sat and missed.
        mastery[try #require(elements.first).id] = .solvesBasics

        let progress = try #require(
            subject.domainProgress(mastery: mastery).first { $0.domain.code == "A" }
        )

        #expect(progress.blockedCount == 0, "Nothing has gone wrong yet.")
        #expect(progress.standing == .inProgress)
    }

    /// And the moment a quiz is actually missed, it does read as a stumble.
    @Test("A missed quiz on a prerequisite turns the 領域 into 手前でつまずき")
    func missedQuizIsAStumble() throws {
        let numbers = try #require(subject.domains.first { $0.code == "A" })
        let elements = subject.elements(inDomain: numbers.id)
        let first = try #require(elements.first)

        var mastery = MasteryRecord(
            levels: [first.id: .understandsMeaning],
            struggling: [first.id]
        )
        mastery[first.id] = .understandsMeaning

        let progress = try #require(
            subject.domainProgress(mastery: mastery).first { $0.domain.code == "A" }
        )

        #expect(progress.blockedCount > 0)
        #expect(progress.standing == .blocked)
    }

    @Test("A fully mastered 領域 reads as strong")
    func masteredDomainIsStrong() throws {
        var mastery = MasteryRecord()
        for element in subject.elements { mastery[element.id] = .stableUnderTime }

        let data = try #require(subject.domainProgress(mastery: mastery).first { $0.domain.code == "D" })
        #expect(data.standing == .strong)
        #expect(data.masteredFraction == 1)
    }

    @Test("An untouched subject reads as not started, not as blocked")
    func untouchedIsNotStarted() {
        for progress in subject.domainProgress(mastery: MasteryRecord()) where progress.totalElements > 0 {
            #expect(progress.masteredCount == 0)
        }
    }
}
