import Foundation
import Testing
@testable import WakaRouteKit

@Suite("Daily route")
struct DailyRouteTests {

    private func step(_ id: String, minutes: Int, done: Bool) -> RouteStep {
        RouteStep(id: id, title: id, subjectName: "数学", kind: .practice, estimatedMinutes: minutes, isComplete: done)
    }

    @Test("Reports the next incomplete step")
    func findsNextStep() throws {
        let route = DailyRoute(steps: [
            step("a", minutes: 5, done: true),
            step("b", minutes: 10, done: false),
            step("c", minutes: 5, done: false)
        ])

        #expect(try #require(route.nextStep).id == "b")
        #expect(route.completedCount == 1)
        #expect(route.isComplete == false)
    }

    @Test("Remaining minutes count only unfinished steps")
    func remainingMinutesExcludeFinished() {
        let route = DailyRoute(steps: [
            step("a", minutes: 8, done: true),
            step("b", minutes: 12, done: false)
        ])

        #expect(route.remainingMinutes == 12)
    }

    @Test("A finished route has no next step")
    func finishedRouteHasNoNextStep() {
        let route = DailyRoute(steps: [step("a", minutes: 5, done: true)])

        #expect(route.isComplete)
        #expect(route.nextStep == nil)
        #expect(route.progress == 1)
    }

    @Test("An empty route is not treated as complete")
    func emptyRouteIsNotComplete() {
        let route = DailyRoute(steps: [])

        #expect(route.isComplete == false, "Nothing to do is not the same as finishing.")
        #expect(route.progress == 0)
    }
}

@Suite("Exam readiness")
struct ExamReadinessTests {

    @Test("Totals across subjects, ignoring the ones with no data")
    func sumsAcrossSubjects() {
        let readiness = ExamReadiness(subjects: [
            SubjectProgress(subject: SampleUnderstandingMap.math, mastery: SampleUnderstandingMap.partwayMastery),
            SubjectProgress(subject: Subject(id: SubjectId("x"), name: "国語", domains: [], elements: []), mastery: MasteryRecord())
        ])

        #expect(readiness.totalElements == SampleUnderstandingMap.math.elements.count)
        #expect(readiness.fraction > 0)
    }

    @Test("No subjects means zero, not a division by zero")
    func emptyIsSafe() {
        let readiness = ExamReadiness(subjects: [])

        #expect(readiness.totalElements == 0)
        #expect(readiness.fraction == 0)
    }
}
