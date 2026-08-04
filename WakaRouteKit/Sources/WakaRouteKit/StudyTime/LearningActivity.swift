import Foundation

/// One thing the student did, whatever kind it was.
///
/// Study time, lesson completions and quiz results arrive from three different
/// places, but a student remembers their day as one sequence. Merging them here
/// keeps that sequence in one type rather than three parallel lists the screen
/// would have to interleave.
public enum LearningActivity: Sendable, Equatable, Identifiable {
    case studied(StudySession)
    case lessonCompleted(courseTitle: String?, lesson: LessonProgress)
    case quiz(QuizAttempt)
    case test(TestAttempt)

    public var id: String {
        switch self {
        case let .studied(session): "s-\(session.id.uuidString)"
        case let .lessonCompleted(_, lesson): "l-\(lesson.lessonId)"
        case let .quiz(attempt): "q-\(attempt.attemptId)"
        case let .test(attempt): "t-\(attempt.resultId)"
        }
    }

    /// When it happened. Activities without a timestamp are dropped rather than
    /// shown at an invented time.
    ///
    /// A session is dated by when it **started**, not when it ended. That
    /// matches `StudyCalendar` and the server's own `studyDate`, so a session
    /// from 23:40 to 00:20 lands on the same day in all three. Dating it by the
    /// end time would put the timeline on a different day from the calendar
    /// directly above it.
    public var occurredAt: Date? {
        switch self {
        case let .studied(session): session.startedAt
        case let .lessonCompleted(_, lesson): lesson.completedAt
        case let .quiz(attempt): attempt.completedAt
        case let .test(attempt): attempt.completedAt
        }
    }

    public var title: String {
        switch self {
        case let .studied(session): session.title
        case let .lessonCompleted(_, lesson): lesson.title ?? "レッスン"
        case let .quiz(attempt): attempt.lessonTitle ?? "確認クイズ"
        case let .test(attempt): attempt.testTitle ?? "確認テスト"
        }
    }

    public var subtitle: String? {
        switch self {
        case let .studied(session): session.subjectName
        case let .lessonCompleted(courseTitle, _): courseTitle
        case let .quiz(attempt): attempt.courseTitle
        case let .test(attempt): attempt.testTitle == nil ? nil : "確認テスト"
        }
    }
}

/// A day's activities, newest day first.
public struct ActivityDay: Sendable, Equatable, Identifiable {
    public var id: Date { date }
    /// Start of day in the display calendar.
    public let date: Date
    public let activities: [LearningActivity]

    /// Total study time recorded that day. Only sessions carry a duration —
    /// completing a lesson takes time too, but not time we measured.
    public func totalStudySeconds(asOf now: Date = Date()) -> Int {
        activities.reduce(0) { total, activity in
            guard case let .studied(session) = activity, session.isCountable else { return total }
            return total + Int(session.duration(asOf: now))
        }
    }
}

public enum ActivityTimeline {

    /// Merges every source into one timeline, grouped by day, newest first.
    ///
    /// Days are calendar days in the given calendar — Asia/Tokyo in the app —
    /// matching how the server attributes sessions and how a student thinks
    /// about "yesterday".
    public static func build(
        sessions: [StudySession] = [],
        lessonCompletions: [(courseTitle: String?, lesson: LessonProgress)] = [],
        quizAttempts: [QuizAttempt] = [],
        testAttempts: [TestAttempt] = [],
        calendar: Calendar = .current
    ) -> [ActivityDay] {
        var activities: [LearningActivity] = []

        activities += sessions.filter(\.isCountable).map(LearningActivity.studied)
        activities += lessonCompletions
            .filter { $0.lesson.isCompleted && $0.lesson.completedAt != nil }
            .map { LearningActivity.lessonCompleted(courseTitle: $0.courseTitle, lesson: $0.lesson) }
        activities += quizAttempts.map(LearningActivity.quiz)
        activities += testAttempts.map(LearningActivity.test)

        let dated = activities.compactMap { activity -> (Date, LearningActivity)? in
            guard let when = activity.occurredAt else { return nil }
            return (when, activity)
        }

        let grouped = Dictionary(grouping: dated) { calendar.startOfDay(for: $0.0) }

        return grouped
            .map { day, entries in
                ActivityDay(
                    date: day,
                    activities: entries
                        .sorted { $0.0 > $1.0 }
                        .map(\.1)
                )
            }
            .sorted { $0.date > $1.date }
    }

    /// `yyyy-MM-dd` for the API's date-range parameters, which are Japanese
    /// calendar days and inclusive at both ends.
    public static func dateParameter(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
