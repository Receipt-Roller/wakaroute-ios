import Foundation
import Testing
@testable import WakaRouteKit

/// Captured verbatim from `GET /api/v1/lessons/{id}` on 2026-08-03 —
/// 数と式 / 正の数・負の数 / 0より小さい数はどこにある？
private let liveLesson = """
{
  "id": "l-1", "sectionId": "s-1", "courseId": "c-1",
  "title": "0より小さい数はどこにある？",
  "summary": "身のまわりの「0より小さい数」に出会う",
  "bodyHtml": "<h1 id=\\"section\\">0より小さい数はどこにある？</h1> <ul><li>負の数が使われる場面がわかる</li></ul>",
  "videoUrl": null, "slidesEmbedUrl": null, "orderIndex": 0, "culture": "ja-JP",
  "materials": [],
  "quiz": {
    "id": "q-1",
    "title": "0より小さい数を理解できたか確認しよう",
    "instructions": null,
    "passingScorePercent": 80,
    "isRequired": true,
    "questions": [
      { "id": "q1", "questionText": "負の数とは、どのような数ですか？", "imageUrl": null,
        "questionType": "MultipleChoiceSingle", "orderIndex": 0,
        "options": [
          { "id": "o1", "text": "0より小さい数", "orderIndex": 0 },
          { "id": "o2", "text": "0より大きい数", "orderIndex": 1 }
        ] },
      { "id": "q2", "questionText": "0℃より5℃低い気温は？", "imageUrl": null,
        "questionType": "MultipleChoiceSingle", "orderIndex": 1,
        "options": [
          { "id": "o3", "text": "−5℃", "orderIndex": 0 },
          { "id": "o4", "text": "+5℃", "orderIndex": 1 }
        ] }
    ]
  }
}
"""

@Suite("Lesson and quiz decoding")
struct QuizTests {

    private func lesson() throws -> LessonDetail {
        try JSONDecoder.wakaRoute.decode(LessonDetail.self, from: Data(liveLesson.utf8))
    }

    @Test("Decodes the live lesson with its embedded quiz")
    func decodesLiveLesson() throws {
        let detail = try lesson()
        let quiz = try #require(detail.quiz)

        #expect(detail.title == "0より小さい数はどこにある？")
        #expect(quiz.passingScorePercent == 80)
        #expect(quiz.isRequired)
        #expect(quiz.questions.count == 2)
    }

    /// Options carry `text`, not the `optionText` the separate 確認テスト
    /// endpoints use. The two look alike and are not interchangeable.
    @Test("Options decode from `text`")
    func optionsUseTextField() throws {
        let quiz = try #require(try lesson().quiz)
        #expect(quiz.questions.first?.options.first?.text == "0より小さい数")
    }

    @Test("Questions are sorted by orderIndex — the teaching sequence matters")
    func questionOrdering() throws {
        let quiz = try #require(try lesson().quiz)
        #expect(quiz.questions.map(\.id) == ["q1", "q2"])
    }

    /// Options keep the order the server sent, and are never re-sorted.
    ///
    /// The server shuffles them per request so the answer's position cannot be
    /// memorised (LMS-DEV t-d1bea79). Sorting by `orderIndex` here would undo
    /// that shuffle without any visible sign.
    @Test("Options are rendered in the order received, not re-sorted")
    func optionsAreNotResorted() throws {
        let json = """
        { "id": "l", "title": "t", "quiz": { "id": "q", "passingScorePercent": 60, "isRequired": false,
          "questions": [ { "id": "a", "questionText": "?", "questionType": "MultipleChoiceSingle",
            "orderIndex": 0, "options": [
              { "id": "third",  "text": "3", "orderIndex": 2 },
              { "id": "first",  "text": "1", "orderIndex": 0 },
              { "id": "second", "text": "2", "orderIndex": 1 } ] } ] } }
        """
        let quiz = try #require(
            try JSONDecoder.wakaRoute.decode(LessonDetail.self, from: Data(json.utf8)).quiz
        )

        #expect(
            quiz.questions[0].options.map(\.id) == ["third", "first", "second"],
            "A shuffled payload must survive decoding unchanged."
        )
    }

    /// A question type the app cannot present is excluded from grading rather
    /// than shown as an unanswerable row — but the count is kept so the student
    /// can be told, instead of being graded on fewer questions in silence.
    @Test("Unknown question types are marked unanswerable, not crashed on")
    func unsupportedQuestionType() throws {
        let json = """
        { "id": "l", "title": "t", "quiz": { "id": "q", "passingScorePercent": 60,
          "isRequired": false, "questions": [
            { "id": "a", "questionText": "?", "questionType": "Matching", "orderIndex": 0, "options": [] },
            { "id": "b", "questionText": "?", "questionType": "MultipleChoiceSingle", "orderIndex": 1,
              "options": [ { "id": "o", "text": "x", "orderIndex": 0 } ] } ] } }
        """
        let quiz = try #require(
            try JSONDecoder.wakaRoute.decode(LessonDetail.self, from: Data(json.utf8)).quiz
        )

        #expect(quiz.questions.count == 2)
        #expect(quiz.questions[0].kind == .unsupported)
        #expect(quiz.questions[0].isAnswerable == false)
        #expect(quiz.questions[1].isAnswerable)
    }

    @Test("A choice question with no options is not answerable")
    func emptyOptionsAreNotAnswerable() throws {
        let json = """
        { "id": "l", "title": "t", "quiz": { "id": "q", "passingScorePercent": 60, "isRequired": false,
          "questions": [ { "id": "a", "questionText": "?", "questionType": "MultipleChoiceSingle",
                           "orderIndex": 0, "options": [] } ] } }
        """
        let quiz = try #require(
            try JSONDecoder.wakaRoute.decode(LessonDetail.self, from: Data(json.utf8)).quiz
        )
        #expect(quiz.questions[0].isAnswerable == false)
    }

    @Test("A lesson with no quiz decodes cleanly")
    func lessonWithoutQuiz() throws {
        let json = #"{ "id": "l", "title": "t", "quiz": null }"#
        let detail = try JSONDecoder.wakaRoute.decode(LessonDetail.self, from: Data(json.utf8))
        #expect(detail.quiz == nil)
    }

    /// Captured from a real submission.
    @Test("The graded result decodes, including the .NET timestamp")
    func decodesResult() throws {
        let json = """
        { "attemptId": "eae8749dd64449df841b88c33e1bba58",
          "quizId": "46b098c36a9749e2a4a58d158cf1e641",
          "scorePercent": 100, "passingScorePercent": 80, "isPassed": true,
          "completedAt": "2026-08-03T06:24:15.1742448Z" }
        """
        let result = try JSONDecoder.wakaRoute.decode(QuizResult.self, from: Data(json.utf8))

        #expect(result.scorePercent == 100)
        #expect(result.isPassed)
        #expect(result.completedAt != nil, "Seven-digit fractional seconds must parse.")
    }

    @Test("Answers encode as the server expects")
    func answerEncoding() throws {
        let data = try JSONEncoder().encode(QuizAnswer(questionId: "q1", optionId: "o1"))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(object?["questionId"] as? String == "q1")
        #expect(object?["optionId"] as? String == "o1")
    }
}

/// Captured from `GET /api/v1/me/progress/{courseId}` on 2026-08-03.
private let liveCourseProgress = """
{
  "lessons": [
    { "lessonId": "7725e3a4", "sectionId": "7974376f", "title": "0より小さい数はどこにある？",
      "orderIndex": 0, "isViewed": true, "isCompleted": true,
      "viewedAt": "2026-08-03T06:24:15.3439002+00:00",
      "completedAt": "2026-08-03T06:24:15.3439214+00:00" },
    { "lessonId": "aaaa1111", "title": "正の数・負の数・0を見分けよう",
      "orderIndex": 1, "isViewed": false, "isCompleted": false,
      "viewedAt": null, "completedAt": null }
  ],
  "courseId": "c-1", "courseTitle": "正の数・負の数", "culture": "ja-JP",
  "totalLessons": 23, "completedLessons": 1, "percentComplete": 4,
  "isCompleted": false, "lastActivityAt": "2026-08-03T06:24:15.3439214+00:00"
}
"""

@Suite("Lesson history")
struct LessonHistoryTests {

    private func progress() throws -> CourseProgress {
        try JSONDecoder.wakaRoute.decode(CourseProgress.self, from: Data(liveCourseProgress.utf8))
    }

    /// The timestamps are what make this a history rather than a checklist.
    @Test("Completion timestamps decode from the live response")
    func decodesTimestamps() throws {
        let done = try #require(try progress().lessons.first { $0.isCompleted })

        #expect(done.completedAt != nil, "Seven-digit fractional seconds must parse.")
        #expect(done.viewedAt != nil)
        #expect(done.sectionId == "7974376f")
    }

    @Test("An unfinished lesson has no timestamps and is not history")
    func unfinishedHasNoTimestamps() throws {
        let pending = try #require(try progress().lessons.first { !$0.isCompleted })

        #expect(pending.completedAt == nil)
        #expect(pending.viewedAt == nil)
    }

    @Test("History is most recently completed first, excluding unfinished lessons")
    func historyIsOrdered() throws {
        let history = try progress().completionHistory

        #expect(history.count == 1)
        #expect(history.allSatisfy { $0.isCompleted && $0.completedAt != nil })
    }

    /// Quiz scores are write-only today (LMS-DEV t-d1bea78): the submit
    /// response is the only place a score ever appears. Nothing in course
    /// progress carries one, so the app cannot show a past result.
    @Test("Course progress carries no quiz score — the gap is real")
    func progressHasNoQuizScore() throws {
        let raw = liveCourseProgress.lowercased()

        #expect(!raw.contains("score"))
        #expect(!raw.contains("quiz"))
        #expect(!raw.contains("attempt"))
    }
}

@Suite("Quiz and test attempt history")
struct AttemptHistoryTests {

    /// Captured from `GET /api/v1/me/quiz-attempts`.
    @Test("Quiz attempts decode with their lesson and course titles")
    func decodesQuizAttempts() throws {
        let json = """
        [ { "attemptId": "a1", "quizId": "q1",
            "lessonId": "l1", "lessonTitle": "0より小さい数はどこにある？",
            "courseId": "c1", "courseTitle": "正の数・負の数",
            "scorePercent": 20, "passingScorePercent": 80, "isPassed": false,
            "startedAt": "2026-08-03T12:00:00.1234567+00:00",
            "completedAt": "2026-08-03T12:01:00.1234567+00:00" } ]
        """
        let attempts = try JSONDecoder.wakaRoute.decode([QuizAttempt].self, from: Data(json.utf8))
        let first = try #require(attempts.first)

        #expect(first.lessonTitle == "0より小さい数はどこにある？")
        #expect(first.courseTitle == "正の数・負の数", "Titles come with the row, so no extra call per line.")
        #expect(first.isPassed == false)
        #expect(first.completedAt != nil)
    }

    /// 「時間内に安定する」 is the top level of the 理解マップ, so passing slowly
    /// is a genuinely different state from passing.
    @Test("A test passed over the time limit is distinguishable from one passed within it")
    func passedButOverTime() throws {
        let json = """
        [ { "resultId": "r1", "testId": "t1", "testTitle": "数と式 確認テスト", "pathId": "p1",
            "scorePercent": 100, "passingScorePercent": 50, "isPassed": true,
            "correctCount": 5, "totalQuestions": 5,
            "completedAt": "2026-08-03T12:00:00Z",
            "timeLimitSeconds": 600, "elapsedSeconds": 900, "isWithinTimeLimit": false } ]
        """
        let attempt = try #require(
            try JSONDecoder.wakaRoute.decode([TestAttempt].self, from: Data(json.utf8)).first
        )

        #expect(attempt.isPassed)
        #expect(attempt.isWithinTimeLimit == false)
        #expect(attempt.passedButOverTime, "Passed, but not within the limit.")
    }

    /// Nil means "cannot be judged", not "within". Treating it as within would
    /// claim a student is exam-ready on no evidence.
    @Test("An untimed test reports nil, and is not counted as over time")
    func untimedTestIsUnknown() throws {
        let json = """
        [ { "resultId": "r2", "scorePercent": 90, "passingScorePercent": 50, "isPassed": true,
            "completedAt": "2026-08-03T12:00:00Z",
            "timeLimitSeconds": null, "elapsedSeconds": null, "isWithinTimeLimit": null } ]
        """
        let attempt = try #require(
            try JSONDecoder.wakaRoute.decode([TestAttempt].self, from: Data(json.utf8)).first
        )

        #expect(attempt.isWithinTimeLimit == nil)
        #expect(attempt.passedButOverTime == false)
    }

    @Test("An empty history decodes rather than failing")
    func emptyHistory() throws {
        #expect(try JSONDecoder.wakaRoute.decode([QuizAttempt].self, from: Data("[]".utf8)).isEmpty)
        #expect(try JSONDecoder.wakaRoute.decode([TestAttempt].self, from: Data("[]".utf8)).isEmpty)
    }

    /// The latest result now rides along with course progress, so a lesson list
    /// can show 「前回 80%」 without a second request.
    @Test("Course progress carries each lesson's latest quiz result")
    func progressCarriesLatestQuizResult() throws {
        let json = """
        { "courseId": "c1", "totalLessons": 2, "completedLessons": 1,
          "percentComplete": 50, "isCompleted": false,
          "lessons": [
            { "lessonId": "l1", "title": "クイズあり", "isViewed": true, "isCompleted": true,
              "completedAt": "2026-08-03T12:00:00Z",
              "latestQuizScorePercent": 80, "latestQuizPassed": true,
              "latestQuizCompletedAt": "2026-08-03T12:05:00Z" },
            { "lessonId": "l2", "title": "クイズなし", "isViewed": false, "isCompleted": false,
              "latestQuizScorePercent": null, "latestQuizPassed": null,
              "latestQuizCompletedAt": null } ] }
        """
        let progress = try JSONDecoder.wakaRoute.decode(CourseProgress.self, from: Data(json.utf8))

        #expect(progress.lessons[0].latestQuizScorePercent == 80)
        #expect(progress.lessons[0].latestQuizPassed == true)
        #expect(progress.lessons[1].latestQuizScorePercent == nil, "No quiz means nil, not zero.")
    }
}

@Suite("Latest quiz result lookup")
struct LatestQuizResultTests {

    private func progress() throws -> CourseProgress {
        let json = """
        { "courseId": "c1", "totalLessons": 3, "completedLessons": 2,
          "percentComplete": 66, "isCompleted": false,
          "lessons": [
            { "lessonId": "passed", "title": "合格した", "isViewed": true, "isCompleted": true,
              "latestQuizScorePercent": 80, "latestQuizPassed": true },
            { "lessonId": "failed", "title": "不合格だった", "isViewed": true, "isCompleted": true,
              "latestQuizScorePercent": 40, "latestQuizPassed": false },
            { "lessonId": "noquiz", "title": "クイズなし", "isViewed": false, "isCompleted": false,
              "latestQuizScorePercent": null, "latestQuizPassed": null } ] }
        """
        return try JSONDecoder.wakaRoute.decode(CourseProgress.self, from: Data(json.utf8))
    }

    @Test("A lesson's own progress is found by id")
    func findsLessonById() throws {
        let found = try #require(try progress().lesson("failed"))

        #expect(found.latestQuizScorePercent == 40)
        #expect(found.latestQuizPassed == false)
    }

    /// Nil is "no result", not zero. Showing 「前回 0%」 for a quiz never sat
    /// would report a failure the student did not have.
    @Test("A lesson with no attempt reports nil, never zero")
    func noAttemptIsNilNotZero() throws {
        let found = try #require(try progress().lesson("noquiz"))

        #expect(found.latestQuizScorePercent == nil)
        #expect(found.latestQuizPassed == nil)
    }

    @Test("An unknown lesson id returns nil rather than a wrong row")
    func unknownLessonIsNil() throws {
        #expect(try progress().lesson("missing") == nil)
    }

    @Test("Passing and failing are distinguishable, not just the number")
    func passedFlagIsSeparateFromScore() throws {
        let passed = try #require(try progress().lesson("passed"))
        let failed = try #require(try progress().lesson("failed"))

        #expect(passed.latestQuizPassed == true)
        #expect(failed.latestQuizPassed == false)
        #expect(passed.latestQuizScorePercent != failed.latestQuizScorePercent)
    }
}
