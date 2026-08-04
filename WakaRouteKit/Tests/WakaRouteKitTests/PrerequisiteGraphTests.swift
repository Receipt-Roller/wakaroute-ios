import Foundation
import Testing
@testable import WakaRouteKit

/// Guards the authored graph itself. It ships in the bundle, so a bad edit is a
/// build-time mistake and this is where it must be caught — at runtime the map
/// can only refuse to draw, which tells a student nothing.
@Suite("The authored 数学 prerequisite graph")
struct PrerequisiteGraphTests {

    private func graph() throws -> PrerequisiteGraph {
        try PrerequisiteGraph.math()
    }

    @Test("It loads, and covers all 26 要素 across the 4 領域")
    func loadsCompletely() throws {
        let graph = try graph()

        #expect(graph.subject == "数学")
        #expect(graph.domains.map(\.code) == ["A", "B", "C", "D"])
        #expect(graph.elements.count == 26)

        for code in ["A", "B", "C", "D"] {
            #expect(graph.elements.contains { $0.domain == code }, "領域 \(code) has no 要素.")
        }
    }

    /// Acyclic, no dangling edges, no duplicates, every 領域 declared.
    @Test("It has no structural problems")
    func noProblems() throws {
        #expect(try graph().problems().isEmpty)
    }

    /// The two examples t-1fa7220 gives for why a linear order cannot express
    /// this: both cross 領域 boundaries.
    @Test("Prerequisites that cross 領域 are present")
    func crossDomainEdges() throws {
        let graph = try graph()

        func requires(_ title: String) throws -> Set<String> {
            let element = try #require(graph.elements.first { $0.title == title })
            let byId = Dictionary(graph.elements.map { ($0.courseId, $0.title) }, uniquingKeysWith: { first, _ in first })
            return Set(element.requires.compactMap { byId[$0] })
        }

        #expect(try requires("三平方の定理") == ["相似", "平方根"], "B 図形 depends on A 数と式.")
        #expect(try requires("一次関数") == ["比例・反比例", "一次方程式"], "C 関数 depends on A 数と式.")
    }

    @Test("Every 中1 starting point has no prerequisites, and everything else has some")
    func rootsAreTheStartingPoints() throws {
        let graph = try graph()
        let roots = graph.elements.filter(\.requires.isEmpty).map(\.title).sorted()

        #expect(roots == ["データの分布", "平面図形・作図", "正の数・負の数"])
    }

    @Test("A cycle is reported rather than silently accepted")
    func detectsCycles() throws {
        let json = """
        { "asOf": "2026-08-04", "subject": "test",
          "domains": [ { "code": "A", "name": "A", "pathId": "p" } ],
          "elements": [
            { "courseId": "x", "title": "X", "domain": "A", "requires": ["y"] },
            { "courseId": "y", "title": "Y", "domain": "A", "requires": ["x"] } ] }
        """
        let graph = try JSONDecoder().decode(PrerequisiteGraph.self, from: Data(json.utf8))

        #expect(graph.problems().contains { $0.hasPrefix("cycle:") })
    }

    @Test("An edge pointing nowhere is reported, and dropped rather than blocking forever")
    func danglingEdge() throws {
        let json = """
        { "asOf": "2026-08-04", "subject": "test",
          "domains": [ { "code": "A", "name": "A", "pathId": "p" } ],
          "elements": [ { "courseId": "x", "title": "X", "domain": "A", "requires": ["gone"] } ] }
        """
        let graph = try JSONDecoder().decode(PrerequisiteGraph.self, from: Data(json.utf8))

        #expect(graph.problems().contains { $0.contains("gone") })
        // Kept out of the built subject: an unresolvable prerequisite is never
        // solid, so leaving it in would block X permanently with no way back.
        let subject = graph.subject(id: SubjectId("test"))
        #expect(subject.elements.first?.prerequisiteIds.isEmpty == true)
    }

    /// A course deleted in MANABU2 must be noticed, not quietly dropped from a
    /// student's map.
    @Test("A course that no longer exists upstream is reported")
    func missingUpstreamCourse() throws {
        let graph = try graph()
        let live = Set(graph.elements.dropFirst().map(\.courseId))
        let first = try #require(graph.elements.first)

        #expect(graph.problems(againstLiveCourseIds: live).contains { $0.contains(first.courseId) })
    }

    /// Names are never keys, so a renamed course must still resolve — and show
    /// its new name.
    @Test("Live titles win over the authored ones")
    func livesTitlesWin() throws {
        let graph = try graph()
        let element = try #require(graph.elements.first { $0.title == "平方根" })

        let subject = graph.subject(
            id: SchoolSubject.math.id,
            titlesByCourseId: [element.courseId: "平方根（改訂）"]
        )

        #expect(subject.elements.contains { $0.name == "平方根（改訂）" })
        #expect(subject.elements.count == 26, "A rename must not lose a 要素.")
    }
}

@Suite("Deriving 理解度 from what the server records")
struct MasteryDerivationTests {

    private func attempt(lesson: String, course: String, passed: Bool, at iso: String) -> QuizAttempt {
        let json = """
        { "attemptId": "\(lesson)-\(iso)", "lessonId": "\(lesson)", "courseId": "\(course)",
          "scorePercent": \(passed ? 100 : 20), "passingScorePercent": 80,
          "isPassed": \(passed), "completedAt": "\(iso)" }
        """
        // swiftlint:disable:next force_try — the literal is always well formed.
        return try! JSONDecoder.wakaRoute.decode(QuizAttempt.self, from: Data(json.utf8))
    }

    private func progress(_ id: String, completed: Int, total: Int) -> CourseProgress {
        CourseProgress(
            courseId: id, totalLessons: total, completedLessons: completed,
            percentComplete: total == 0 ? 0 : completed * 100 / total,
            isCompleted: total > 0 && completed == total
        )
    }

    @Test("Untouched is まだ")
    func untouched() {
        let record = MasteryDerivation.record(progress: [], quizAttempts: [])
        #expect(record[ElementId("c-1")] == .notStarted)
    }

    @Test("Lessons read but the quiz failed is 意味がわかる, not 基本を解ける")
    func readButFailed() {
        let record = MasteryDerivation.record(
            progress: [progress("c-1", completed: 3, total: 3)],
            quizAttempts: [attempt(lesson: "l-1", course: "c-1", passed: false, at: "2026-08-01T10:00:00Z")]
        )
        #expect(record[ElementId("c-1")] == .understandsMeaning)
    }

    @Test("Finishing the 要素 with its quizzes passed reaches 基本を解ける")
    func passed() {
        let record = MasteryDerivation.record(
            progress: [progress("c-1", completed: 3, total: 3)],
            quizAttempts: [attempt(lesson: "l-1", course: "c-1", passed: true, at: "2026-08-01T10:00:00Z")]
        )
        #expect(record[ElementId("c-1")] == .solvesBasics)
        #expect(record.struggling.isEmpty)
    }

    /// The one a real student hit: 正の数・負の数 is 23 lessons long, and passing
    /// the quiz on lesson 1 said nothing about the other 22 — but marked the
    /// whole 要素 基本を解ける, which then unblocked everything behind it.
    @Test("One passed quiz early in a long 要素 does not certify the whole thing")
    func oneQuizDoesNotCertifyALongCourse() {
        let record = MasteryDerivation.record(
            progress: [progress("c-1", completed: 1, total: 23)],
            quizAttempts: [attempt(lesson: "l-1", course: "c-1", passed: true, at: "2026-08-01T10:00:00Z")]
        )

        #expect(record[ElementId("c-1")] == .understandsMeaning)
        #expect(record.struggling.isEmpty, "Passing is not struggling — they are simply partway.")
    }

    /// The distinction the 領域 label depends on: 意味がわかる covers both
    /// "reading through it" and "sat the quiz and missed", and only the second
    /// may be reported as 手前でつまずき.
    @Test("Only a missed quiz marks a 要素 as struggling")
    func strugglingNeedsAMissedQuiz() {
        let partway = MasteryDerivation.record(
            progress: [progress("c-1", completed: 2, total: 9)],
            quizAttempts: []
        )
        #expect(partway[ElementId("c-1")] == .understandsMeaning)
        #expect(partway.struggling.isEmpty)

        let missed = MasteryDerivation.record(
            progress: [progress("c-2", completed: 9, total: 9)],
            quizAttempts: [attempt(lesson: "l-1", course: "c-2", passed: false, at: "2026-08-01T10:00:00Z")]
        )
        #expect(missed[ElementId("c-2")] == .understandsMeaning)
        #expect(missed.struggling == [ElementId("c-2")])
    }

    /// Only the latest attempt counts, so redoing the work actually clears it.
    @Test("A later pass replaces an earlier failure")
    func laterPassWins() {
        let record = MasteryDerivation.record(
            progress: [progress("c-1", completed: 3, total: 3)],
            quizAttempts: [
                attempt(lesson: "l-1", course: "c-1", passed: false, at: "2026-08-01T10:00:00Z"),
                attempt(lesson: "l-1", course: "c-1", passed: true, at: "2026-08-03T10:00:00Z")
            ]
        )
        #expect(record[ElementId("c-1")] == .solvesBasics)
    }

    @Test("One failed quiz in a course holds the whole 要素 back")
    func oneFailureHoldsTheCourse() {
        let record = MasteryDerivation.record(
            progress: [progress("c-1", completed: 5, total: 5)],
            quizAttempts: [
                attempt(lesson: "l-1", course: "c-1", passed: true, at: "2026-08-01T10:00:00Z"),
                attempt(lesson: "l-2", course: "c-1", passed: false, at: "2026-08-02T10:00:00Z")
            ]
        )
        #expect(record[ElementId("c-1")] == .understandsMeaning)
    }

    /// A 要素 nobody wrote a quiz for must not block everything downstream, or
    /// the student is sent back to work they have already finished.
    @Test("A course with no quiz counts as 基本を解ける once every lesson is done")
    func courseWithoutAQuiz() {
        let record = MasteryDerivation.record(
            progress: [progress("c-1", completed: 4, total: 4)],
            quizAttempts: []
        )
        #expect(record[ElementId("c-1")] == .solvesBasics)
    }

    @Test("A course part-way through, with no quiz sat, is 意味がわかる")
    func partway() {
        let record = MasteryDerivation.record(
            progress: [progress("c-1", completed: 1, total: 4)],
            quizAttempts: []
        )
        #expect(record[ElementId("c-1")] == .understandsMeaning)
    }

    /// The point of the whole file. 確認テスト do not exist yet, so nothing may
    /// claim a level that needs one.
    @Test("Nothing is ever reported above 基本を解ける")
    func nothingClaimsUnmeasurableLevels() {
        let record = MasteryDerivation.record(
            progress: [progress("c-1", completed: 9, total: 9)],
            quizAttempts: [attempt(lesson: "l-1", course: "c-1", passed: true, at: "2026-08-01T10:00:00Z")]
        )

        #expect(record[ElementId("c-1")] <= MasteryDerivation.highestMeasurable)
        #expect(record[ElementId("c-1")] < MasteryLevel.masteredThreshold, "習得 needs 確認テスト.")
    }
}

@Suite("The map traversal over the real 数学 graph")
struct LiveGraphTraversalTests {

    private func subject() throws -> Subject {
        try PrerequisiteGraph.math().subject(id: SchoolSubject.math.id)
    }

    private func courseId(_ title: String) throws -> String {
        try #require(try PrerequisiteGraph.math().elements.first { $0.title == title }).courseId
    }

    /// The product thesis, run against the real graph: a student failing
    /// 一次関数 whose 一次方程式 is not solid is sent back to 一次方程式, not told
    /// to practise 一次関数 harder.
    @Test("A student stuck on 一次関数 is sent back to the real cause")
    func tracesBackToTheCause() throws {
        let subject = try subject()
        var mastery = MasteryRecord()
        mastery[ElementId(try courseId("正の数・負の数"))] = .solvesBasics
        mastery[ElementId(try courseId("文字を用いた式"))] = .solvesBasics
        mastery[ElementId(try courseId("変数と関数"))] = .solvesBasics
        mastery[ElementId(try courseId("比例・反比例"))] = .solvesBasics
        // 一次方程式 attempted and not solid — the actual gap.
        mastery[ElementId(try courseId("一次方程式"))] = .understandsMeaning
        mastery[ElementId(try courseId("一次関数"))] = .understandsMeaning

        let focus = StudyFocus(subject: subject, mastery: mastery)
        let element = try #require(subject.elements.first { $0.id == ElementId(try courseId("一次関数")) })

        #expect(focus.rootCauses(of: element).map(\.name) == ["一次方程式"])
    }

    /// 三平方の定理 has two parents in different 領域. Both must be reported, or
    /// the student fixes one and is still blocked with no explanation.
    @Test("Both causes are found when a 要素 has two")
    func twoCauses() throws {
        let subject = try subject()
        let focus = StudyFocus(subject: subject, mastery: MasteryRecord())
        let element = try #require(subject.elements.first { $0.name == "三平方の定理" })

        // Nothing studied at all, so tracing back reaches the two 中1 roots the
        // whole chain rests on.
        let causes = Set(focus.rootCauses(of: element).map(\.name))
        #expect(causes == ["平面図形・作図", "正の数・負の数"])
    }

    @Test("A student who has done nothing is pointed at the starting points, not the hardest topic")
    func freshStudent() throws {
        let subject = try subject()
        let focus = StudyFocus(subject: subject, mastery: MasteryRecord())

        let names = Set(focus.recommendations(limit: 3).map(\.element.name))
        #expect(names.isSubset(of: ["正の数・負の数", "平面図形・作図", "データの分布"]))
    }

    /// End to end on a real account's data, captured from production on
    /// 2026-08-04: one lesson of 正の数・負の数 finished, its quiz sat and failed
    /// at 40% against a 80% line, nothing else touched.
    ///
    /// The expected answer is the product in one sentence — go back to
    /// 正の数・負の数, because everything in 数と式 is waiting on it.
    @Test("A real account's record produces the trace-back, not a drill on the same quiz")
    func realAccountEndToEnd() throws {
        let attempts = """
        [ { "attemptId": "cde0c9041c1445eab8cb4c05476ea9af",
            "lessonId": "7725e3a466ec41389f4216a26d2795c7",
            "lessonTitle": "0より小さい数はどこにある？",
            "courseId": "54ead490c3914e4c841555d33703456d",
            "courseTitle": "正の数・負の数",
            "scorePercent": 40, "passingScorePercent": 80, "isPassed": false,
            "startedAt": "2026-08-04T00:36:31.4063979+00:00",
            "completedAt": "2026-08-04T00:36:32.3248863+00:00" } ]
        """
        let progress = """
        [ { "courseId": "54ead490c3914e4c841555d33703456d", "courseTitle": "正の数・負の数",
            "totalLessons": 23, "completedLessons": 1, "percentComplete": 4,
            "isCompleted": false, "lastActivityAt": "2026-08-04T00:36:25.3842974+00:00" } ]
        """

        let record = MasteryDerivation.record(
            progress: try JSONDecoder.wakaRoute.decode([CourseProgress].self, from: Data(progress.utf8)),
            quizAttempts: try JSONDecoder.wakaRoute.decode([QuizAttempt].self, from: Data(attempts.utf8))
        )

        let subject = try subject()
        #expect(
            record[ElementId(try courseId("正の数・負の数"))] == .understandsMeaning,
            "Read it, but the quiz says it is not solid."
        )

        let top = try #require(
            StudyFocus(subject: subject, mastery: record)
                .recommendations(limit: 3)
                .first
        )
        #expect(top.element.name == "正の数・負の数")
        #expect(
            top.unblocks.contains { $0.name == "文字を用いた式" },
            "The whole of 数と式 is waiting behind it."
        )
    }
}
