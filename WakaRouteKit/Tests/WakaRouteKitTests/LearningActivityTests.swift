import Foundation
import Testing
@testable import WakaRouteKit

private let jst: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    return calendar
}()

private func at(_ iso: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    return formatter.date(from: iso)!
}

private func session(_ start: String, minutes: Int) -> StudySession {
    StudySession(
        startedAt: at(start),
        endedAt: at(start).addingTimeInterval(TimeInterval(minutes * 60)),
        title: "文字式の練習", subjectName: "数学", kind: .practice
    )
}

private func lessonProgress(_ completedAt: String?, title: String = "レッスン") throws -> LessonProgress {
    let completed = completedAt.map { "\"\($0)\"" } ?? "null"
    let json = """
    { "lessonId": "l-\(title)", "title": "\(title)",
      "isViewed": true, "isCompleted": \(completedAt != nil),
      "completedAt": \(completed) }
    """
    return try JSONDecoder.wakaRoute.decode(LessonProgress.self, from: Data(json.utf8))
}

private func quizAttempt(_ completedAt: String, score: Int) throws -> QuizAttempt {
    let json = """
    { "attemptId": "a-\(completedAt)-\(score)", "lessonTitle": "0より小さい数はどこにある？",
      "courseTitle": "正の数・負の数", "scorePercent": \(score),
      "passingScorePercent": 80, "isPassed": \(score >= 80),
      "completedAt": "\(completedAt)" }
    """
    return try JSONDecoder.wakaRoute.decode(QuizAttempt.self, from: Data(json.utf8))
}

@Suite("Learning activity timeline")
struct LearningActivityTests {

    @Test("Merges every source into one timeline, newest day first")
    func mergesSources() throws {
        let days = ActivityTimeline.build(
            sessions: [session("2026-08-01T20:00:00+09:00", minutes: 20)],
            lessonCompletions: [(courseTitle: "正の数・負の数", lesson: try lessonProgress("2026-08-03T19:00:00+09:00"))],
            quizAttempts: [try quizAttempt("2026-08-03T19:05:00+09:00", score: 80)],
            calendar: jst
        )

        #expect(days.count == 2)
        #expect(days[0].date > days[1].date, "Newest day first.")
        #expect(days[0].activities.count == 2, "8/3 has the lesson and the quiz.")
        #expect(days[1].activities.count == 1)
    }

    /// Within a day, most recent first — a student scanning back through their
    /// evening reads it in the order they lived it, reversed.
    @Test("Within a day, activities are newest first")
    func orderedWithinDay() throws {
        let days = ActivityTimeline.build(
            lessonCompletions: [(courseTitle: nil, lesson: try lessonProgress("2026-08-03T19:00:00+09:00", title: "先"))],
            quizAttempts: [try quizAttempt("2026-08-03T20:00:00+09:00", score: 60)],
            calendar: jst
        )

        let titles = try #require(days.first).activities.map(\.title)
        #expect(titles.first == "0より小さい数はどこにある？", "20:00 の方が先頭。")
    }

    /// A lesson opened but never finished is not something the student did.
    @Test("Unfinished lessons are excluded")
    func excludesUnfinishedLessons() throws {
        let days = ActivityTimeline.build(
            lessonCompletions: [(courseTitle: nil, lesson: try lessonProgress(nil, title: "未完了"))],
            calendar: jst
        )
        #expect(days.isEmpty)
    }

    @Test("Activities without a timestamp are dropped, never shown at an invented time")
    func dropsUndatedActivities() throws {
        let json = """
        { "attemptId": "a1", "scorePercent": 50, "passingScorePercent": 80,
          "isPassed": false, "completedAt": null }
        """
        let undated = try JSONDecoder.wakaRoute.decode(QuizAttempt.self, from: Data(json.utf8))

        #expect(ActivityTimeline.build(quizAttempts: [undated], calendar: jst).isEmpty)
    }

    /// Sessions crossing midnight group by the day they started, matching how
    /// the server attributes them and how the calendar counts them.
    @Test("A late-night session groups with the day it started")
    func midnightGroupsWithStartDay() {
        let days = ActivityTimeline.build(
            sessions: [session("2026-08-02T23:40:00+09:00", minutes: 40)],
            calendar: jst
        )

        #expect(days.count == 1)
        #expect(jst.component(.day, from: days[0].date) == 2, "Attributed to 8/2, not 8/3.")
    }

    @Test("Only sessions contribute to a day's study time")
    func onlySessionsCountTime() throws {
        let day = try #require(
            ActivityTimeline.build(
                sessions: [session("2026-08-03T19:00:00+09:00", minutes: 25)],
                lessonCompletions: [(courseTitle: nil, lesson: try lessonProgress("2026-08-03T20:00:00+09:00"))],
                quizAttempts: [try quizAttempt("2026-08-03T20:05:00+09:00", score: 100)],
                calendar: jst
            ).first
        )

        #expect(day.activities.count == 3)
        #expect(day.totalStudySeconds(asOf: at("2026-08-03T23:00:00+09:00")) == 1500,
                "Completing a lesson takes time, but not time we measured.")
    }

    @Test("Repeated attempts at the same quiz all appear")
    func keepsEveryAttempt() throws {
        let days = ActivityTimeline.build(
            quizAttempts: [
                try quizAttempt("2026-08-03T19:00:00+09:00", score: 40),
                try quizAttempt("2026-08-03T19:30:00+09:00", score: 80)
            ],
            calendar: jst
        )

        #expect(try #require(days.first).activities.count == 2,
                "Improving over several attempts is the story worth showing.")
    }

    @Test("An empty timeline is empty, not a crash")
    func emptyIsSafe() {
        #expect(ActivityTimeline.build(calendar: jst).isEmpty)
    }

    @Test("Date parameters are formatted for the API's inclusive JST range")
    func formatsDateParameter() {
        #expect(ActivityTimeline.dateParameter(at("2026-08-03T23:59:00+09:00"), calendar: jst) == "2026-08-03")
        #expect(ActivityTimeline.dateParameter(at("2026-08-04T00:01:00+09:00"), calendar: jst) == "2026-08-04")
    }
}
