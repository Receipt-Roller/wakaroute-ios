import Foundation

/// One step on today's route.
public struct RouteStep: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable, Codable {
        case learn      // 学ぶ
        case practice   // 練習
        case review     // 復習
        case check      // 確認テスト
    }

    public let id: String
    public let title: String
    public let subjectName: String
    public let kind: Kind
    public let estimatedMinutes: Int
    public let isComplete: Bool

    public init(
        id: String,
        title: String,
        subjectName: String,
        kind: Kind,
        estimatedMinutes: Int,
        isComplete: Bool = false
    ) {
        self.id = id
        self.title = title
        self.subjectName = subjectName
        self.kind = kind
        self.estimatedMinutes = estimatedMinutes
        self.isComplete = isComplete
    }
}

/// 今日の学習ルート — deliberately short. Three or four steps is a session a
/// student can finish, and finishing is what makes them come back.
public struct DailyRoute: Sendable, Equatable {
    public let steps: [RouteStep]

    public init(steps: [RouteStep]) {
        self.steps = steps
    }

    public var completedCount: Int { steps.filter(\.isComplete).count }
    public var isComplete: Bool { !steps.isEmpty && completedCount == steps.count }

    public var progress: Double {
        steps.isEmpty ? 0 : Double(completedCount) / Double(steps.count)
    }

    /// The next thing to actually tap. Nil once the day is done.
    public var nextStep: RouteStep? {
        steps.first { !$0.isComplete }
    }

    public var remainingMinutes: Int {
        steps.filter { !$0.isComplete }.reduce(0) { $0 + $1.estimatedMinutes }
    }
}

/// Consecutive days with study activity.
///
/// Shown as encouragement, never as a penalty. A broken streak for a student
/// preparing for 受験 is a bad day, not a failure worth punishing.
public struct StudyStreak: Sendable, Equatable {
    public let days: Int
    public let studiedToday: Bool

    public init(days: Int, studiedToday: Bool) {
        self.days = days
        self.studiedToday = studiedToday
    }
}

/// Overall readiness across the five subjects, for the headline ring.
public struct ExamReadiness: Sendable, Equatable {
    public let masteredElements: Int
    public let totalElements: Int
    public let blockedElements: Int

    public init(subjects: [SubjectProgress]) {
        masteredElements = subjects.reduce(0) { $0 + $1.masteredCount }
        totalElements = subjects.reduce(0) { $0 + $1.totalElements }
        blockedElements = subjects.reduce(0) { $0 + $1.blockedCount }
    }

    public var fraction: Double {
        totalElements == 0 ? 0 : Double(masteredElements) / Double(totalElements)
    }
}
