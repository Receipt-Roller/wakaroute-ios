import Foundation
import Testing
@testable import WakaRouteKit

private func at(_ iso: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    return formatter.date(from: iso)!
}

/// Built through the decoder so the tests exercise the same path the app does.
private func attempt(
    id: String,
    lessonId: String?,
    lessonTitle: String = "レッスン",
    courseId: String? = "c-1",
    score: Int,
    passing: Int = 80,
    completedAt: String?
) -> QuizAttempt {
    var fields: [String] = [
        #""attemptId": "\#(id)""#,
        #""scorePercent": \#(score)"#,
        #""passingScorePercent": \#(passing)"#,
        #""isPassed": \#(score >= passing)"#,
        #""lessonTitle": "\#(lessonTitle)""#
    ]
    if let lessonId { fields.append(#""lessonId": "\#(lessonId)""#) }
    if let courseId { fields.append(#""courseId": "\#(courseId)""#) }
    if let completedAt { fields.append(#""completedAt": "\#(completedAt)""#) }

    let json = "{ \(fields.joined(separator: ", ")) }"
    // swiftlint:disable:next force_try — the literal is always well formed.
    return try! JSONDecoder.wakaRoute.decode(QuizAttempt.self, from: Data(json.utf8))
}

private func path(_ id: String, subject: String, courses: Int) -> LearningPathSummary {
    LearningPathSummary(id: id, name: "領域", labels: [subject], courseCount: courses)
}

private func courseProgress(
    _ id: String,
    title: String = "コース",
    completed: Int,
    total: Int,
    lastActivityAt: String? = nil
) -> CourseProgress {
    CourseProgress(
        courseId: id,
        courseTitle: title,
        totalLessons: total,
        completedLessons: completed,
        percentComplete: total == 0 ? 0 : completed * 100 / total,
        isCompleted: total > 0 && completed == total,
        lastActivityAt: lastActivityAt.map(at)
    )
}

@Suite("Home digest")
struct HomeDigestTests {

    @Test("A brand-new learner is not shown a screen full of zeroes as if it were a record")
    func firstLaunch() {
        let digest = HomeDigest.make(
            catalog: ContentCatalog(paths: [path("p1", subject: "数学", courses: 8)], progress: [])
        )

        #expect(digest.hasContent, "Content exists even though nothing has been studied.")
        #expect(digest.hasStarted == false)
        #expect(digest.nextSteps.isEmpty)
    }

    /// The whole point of the section: a failed quiz is the one thing we know
    /// for certain did not stick.
    @Test("A failed quiz is suggested before an unfinished course")
    func failedQuizComesFirst() {
        let digest = HomeDigest.make(
            catalog: ContentCatalog(
                paths: [],
                progress: [courseProgress("c-9", completed: 3, total: 10, lastActivityAt: "2026-08-04T10:00:00+09:00")]
            ),
            quizAttempts: [
                attempt(id: "a1", lessonId: "l-1", score: 60, completedAt: "2026-08-01T10:00:00+09:00")
            ]
        )

        #expect(digest.nextSteps.count == 2)
        #expect(digest.nextSteps[0].lessonId == "l-1")
        #expect(digest.nextSteps[0].reason == .retryQuiz(scorePercent: 60, passingScorePercent: 80))
        #expect(digest.nextSteps[1].courseId == "c-9")
    }

    /// Failing and later passing means it is fixed. Sending the student back
    /// would be telling them their own work did not count.
    @Test("A later pass removes the earlier failure")
    func passingClearsTheRetry() {
        let digest = HomeDigest.make(
            catalog: ContentCatalog(paths: [], progress: []),
            quizAttempts: [
                attempt(id: "old", lessonId: "l-1", score: 60, completedAt: "2026-08-01T10:00:00+09:00"),
                attempt(id: "new", lessonId: "l-1", score: 90, completedAt: "2026-08-03T10:00:00+09:00")
            ]
        )

        #expect(digest.nextSteps.isEmpty)
    }

    @Test("A later failure on a lesson previously passed does come back")
    func regressionIsSuggestedAgain() {
        let digest = HomeDigest.make(
            catalog: ContentCatalog(paths: [], progress: []),
            quizAttempts: [
                attempt(id: "old", lessonId: "l-1", score: 90, completedAt: "2026-08-01T10:00:00+09:00"),
                attempt(id: "new", lessonId: "l-1", score: 40, completedAt: "2026-08-03T10:00:00+09:00")
            ]
        )

        #expect(digest.nextSteps.map(\.id) == ["quiz-new"])
    }

    /// Server order is not trusted: the newest attempt wins whichever way the
    /// list happened to arrive.
    @Test("The newest attempt wins regardless of the order received")
    func orderReceivedDoesNotMatter() {
        let older = attempt(id: "old", lessonId: "l-1", score: 30, completedAt: "2026-08-01T10:00:00+09:00")
        let newer = attempt(id: "new", lessonId: "l-1", score: 95, completedAt: "2026-08-03T10:00:00+09:00")

        for attempts in [[older, newer], [newer, older]] {
            let digest = HomeDigest.make(
                catalog: ContentCatalog(paths: [], progress: []),
                quizAttempts: attempts
            )
            #expect(digest.nextSteps.isEmpty, "The pass is the latest word either way.")
        }
    }

    @Test("An attempt with no lesson or no timestamp is left out rather than guessed at")
    func unusableAttemptsAreDropped() {
        let digest = HomeDigest.make(
            catalog: ContentCatalog(paths: [], progress: []),
            quizAttempts: [
                attempt(id: "a1", lessonId: nil, score: 10, completedAt: "2026-08-01T10:00:00+09:00"),
                attempt(id: "a2", lessonId: "l-2", score: 10, completedAt: nil)
            ]
        )

        #expect(digest.nextSteps.isEmpty)
    }

    /// Two rows about one course saying different things is worse than one.
    @Test("A course already named by a failed quiz is not also listed as unfinished")
    func noDuplicateCourse() {
        let digest = HomeDigest.make(
            catalog: ContentCatalog(
                paths: [],
                progress: [courseProgress("c-1", completed: 2, total: 9, lastActivityAt: "2026-08-04T10:00:00+09:00")]
            ),
            quizAttempts: [
                attempt(id: "a1", lessonId: "l-1", courseId: "c-1", score: 50, completedAt: "2026-08-04T09:00:00+09:00")
            ]
        )

        #expect(digest.nextSteps.count == 1)
        #expect(digest.nextSteps[0].id == "quiz-a1")
    }

    @Test("Unfinished courses come back in the order they were last worked on")
    func resumeOrdering() {
        let digest = HomeDigest.make(
            catalog: ContentCatalog(
                paths: [],
                progress: [
                    courseProgress("older", completed: 5, total: 10, lastActivityAt: "2026-07-01T10:00:00+09:00"),
                    courseProgress("newer", completed: 1, total: 10, lastActivityAt: "2026-08-03T10:00:00+09:00")
                ]
            )
        )

        #expect(digest.nextSteps.map(\.courseId) == ["newer", "older"])
    }

    @Test("A finished course, and one never opened, are both left off the list")
    func onlyUnfinishedStartedCourses() {
        let digest = HomeDigest.make(
            catalog: ContentCatalog(
                paths: [],
                progress: [
                    courseProgress("done", completed: 10, total: 10, lastActivityAt: "2026-08-03T10:00:00+09:00"),
                    courseProgress("untouched", completed: 0, total: 10)
                ]
            )
        )

        #expect(digest.nextSteps.isEmpty)
    }

    @Test("The list is capped so home stays a glance, not a backlog")
    func respectsLimit() {
        let progress = (1...9).map {
            courseProgress("c-\($0)", completed: 1, total: 10, lastActivityAt: "2026-08-0\($0)T10:00:00+09:00")
        }
        let digest = HomeDigest.make(catalog: ContentCatalog(paths: [], progress: progress))

        #expect(digest.nextSteps.count == 3)
    }

    // MARK: - Going back to the prerequisite

    private func recommendation(
        _ name: String,
        courseId: String,
        level: MasteryLevel = .understandsMeaning,
        unblocks: [String]
    ) -> StudyRecommendation {
        StudyRecommendation(
            element: LearningElement(id: ElementId(courseId), name: name, domainId: "A"),
            currentLevel: level,
            unblocks: unblocks.map {
                LearningElement(id: ElementId("blocked-\($0)"), name: $0, domainId: "A")
            }
        )
    }

    /// The product's whole argument. Telling a student stuck on 一次関数 to retry
    /// the 一次関数 quiz is useless if the real gap is 一次方程式.
    @Test("Going back to the prerequisite outranks retrying the quiz that failed")
    func traceBackComesFirst() {
        let digest = HomeDigest.make(
            catalog: ContentCatalog(paths: [], progress: []),
            quizAttempts: [
                attempt(id: "a1", lessonId: "l-9", courseId: "c-9", score: 40, completedAt: "2026-08-04T10:00:00+09:00")
            ],
            recommendations: [recommendation("一次方程式", courseId: "c-1", unblocks: ["一次関数"])]
        )

        #expect(digest.nextSteps.count == 2)
        #expect(digest.nextSteps[0].title == "一次方程式")
        #expect(digest.nextSteps[0].reason == .unblock(currentLevel: .understandsMeaning, isStruggling: false, unblocks: ["一次関数"]))
        #expect(digest.nextSteps[1].id == "quiz-a1")
    }

    /// A recommendation with nothing behind it is just "the next thing", which
    /// the retry and resume rows already say with better evidence.
    @Test("A recommendation that unblocks nothing is left out")
    func recommendationWithoutUnblocksIsDropped() {
        let digest = HomeDigest.make(
            catalog: ContentCatalog(paths: [], progress: []),
            recommendations: [recommendation("平面図形・作図", courseId: "c-1", level: .notStarted, unblocks: [])]
        )

        #expect(digest.nextSteps.isEmpty)
    }

    /// One course, one row. Two rows about the same course saying different
    /// things is worse than one.
    @Test("A course named as a blocker is not also listed as a failed quiz or as unfinished")
    func traceBackAbsorbsTheOtherRows() {
        let digest = HomeDigest.make(
            catalog: ContentCatalog(
                paths: [],
                progress: [courseProgress("c-1", completed: 1, total: 23, lastActivityAt: "2026-08-04T10:00:00+09:00")]
            ),
            quizAttempts: [
                attempt(id: "a1", lessonId: "l-1", courseId: "c-1", score: 40, completedAt: "2026-08-04T09:00:00+09:00")
            ],
            recommendations: [recommendation("正の数・負の数", courseId: "c-1", unblocks: ["文字を用いた式"])]
        )

        #expect(digest.nextSteps.count == 1)
        #expect(digest.nextSteps[0].id == "unblock-c-1")
    }

    /// A student who has not begun has not stumbled.
    ///
    /// The card wording turns on this level: 未着手 reads 「ここから始めると」,
    /// anything higher reads 「進むために必要です」. Telling a 中1 on their first
    /// launch to go *back* to a topic they have never opened would be both
    /// wrong and discouraging — the same distinction 領域 already make between
    /// これから and 手前でつまずき. Caught on an iOS 17 device, not here.
    @Test("A first-launch suggestion is marked 未着手, so it can be worded as a starting point")
    func firstLaunchSuggestionIsNotAStumble() {
        let digest = HomeDigest.make(
            catalog: ContentCatalog(paths: [], progress: []),
            recommendations: [
                recommendation("正の数・負の数", courseId: "c-1", level: .notStarted, unblocks: ["文字を用いた式"])
            ]
        )

        #expect(digest.nextSteps.first?.reason == .unblock(currentLevel: .notStarted, isStruggling: false, unblocks: ["文字を用いた式"]))
        #expect(digest.hasStarted == false)
    }

    /// The 要素 id is the MANABU2 course id, which is what makes the map's
    /// advice openable rather than a label the student cannot act on.
    @Test("A trace-back row carries the course id, so it can be opened")
    func traceBackIsNavigable() {
        let digest = HomeDigest.make(
            catalog: ContentCatalog(paths: [], progress: []),
            recommendations: [recommendation("平方根", courseId: "b6b5cad3", unblocks: ["三平方の定理"])]
        )

        #expect(digest.nextSteps.first?.courseId == "b6b5cad3")
    }

    // MARK: - Per-subject progress

    /// Without the path→course mapping every subject reads 0, which looks like
    /// a student who has done nothing rather than a mapping we have not loaded.
    @Test("Subject progress needs the path structure, and says zero without it")
    func subjectProgressNeedsStructure() {
        let paths = [path("p-math", subject: "数学", courses: 2)]
        let progress = [
            courseProgress("c-1", completed: 4, total: 4),
            courseProgress("c-2", completed: 1, total: 4)
        ]

        let blind = ContentCatalog(paths: paths, progress: progress)
        #expect(blind.subjects.first { $0.subject == .math }?.completedCourses == 0)

        var structure = ContentStructure()
        structure.record(pathId: "p-math", courses: [.init(id: "c-1", title: "コース"), .init(id: "c-2", title: "コース")], courseCount: 2)

        let mapped = ContentCatalog(paths: paths, progress: progress, structure: structure)
        let math = mapped.subjects.first { $0.subject == .math }
        #expect(math?.completedCourses == 1)
        #expect(math?.startedCourses == 2, "Both were opened; only one is finished.")
        #expect(math?.totalCourses == 2)
    }

    @Test("Overall progress is completed courses over published courses")
    func overallProgress() {
        var structure = ContentStructure()
        structure.record(pathId: "p-math", courses: [.init(id: "c-1", title: "コース"), .init(id: "c-2", title: "コース")], courseCount: 2)
        structure.record(pathId: "p-jp", courses: [.init(id: "c-3", title: "コース"), .init(id: "c-4", title: "コース")], courseCount: 2)

        let digest = HomeDigest.make(
            catalog: ContentCatalog(
                paths: [path("p-math", subject: "数学", courses: 2), path("p-jp", subject: "国語", courses: 2)],
                progress: [courseProgress("c-1", completed: 4, total: 4)],
                structure: structure
            )
        )

        #expect(digest.totalCourses == 4)
        #expect(digest.completedCourses == 1)
        #expect(digest.progressFraction == 0.25)
        #expect(digest.hasStarted)
    }
}

@Suite("Content structure cache")
struct ContentStructureTests {

    @Test("A path never fetched is stale")
    func unknownPathIsStale() {
        let structure = ContentStructure()
        #expect(structure.stalePathIds(against: [path("p1", subject: "数学", courses: 8)]) == ["p1"])
    }

    /// The staleness check is what lets new content appear the same day the
    /// content team publishes it, rather than whenever a timer lapses.
    @Test("A path whose course count changed is stale again")
    func changedCountIsStale() {
        var structure = ContentStructure()
        structure.record(pathId: "p1", courses: [.init(id: "c-1", title: "コース")], courseCount: 1)

        #expect(structure.stalePathIds(against: [path("p1", subject: "数学", courses: 1)]).isEmpty)
        #expect(structure.stalePathIds(against: [path("p1", subject: "数学", courses: 2)]) == ["p1"])
    }

    @Test("Course to path lookup covers every recorded path")
    func courseLookup() {
        var structure = ContentStructure()
        structure.record(pathId: "p1", courses: [.init(id: "c-1", title: "コース"), .init(id: "c-2", title: "コース")], courseCount: 2)
        structure.record(pathId: "p2", courses: [.init(id: "c-3", title: "コース")], courseCount: 1)

        let byCourse = structure.pathIdByCourse
        #expect(byCourse["c-2"] == "p1")
        #expect(byCourse["c-3"] == "p2")
        #expect(byCourse["missing"] == nil)
    }

    @Test("It survives a round trip through the store")
    func roundTrip() throws {
        var structure = ContentStructure()
        structure.record(pathId: "p1", courses: [.init(id: "c-1", title: "コース")], courseCount: 1)

        let store = InMemoryContentStructureStore()
        try store.save(structure)
        let encoded = try JSONEncoder.wakaRoute.encode(try store.load())
        let decoded = try JSONDecoder.wakaRoute.decode(ContentStructure.self, from: encoded)

        #expect(decoded == structure)
    }
}
