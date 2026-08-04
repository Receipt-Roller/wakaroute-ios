import Foundation

/// One day's study, for the calendar.
public struct DailyStudyTotal: Identifiable, Sendable, Equatable {
    public var id: Date { date }
    /// Start of day in the display calendar.
    public let date: Date
    public let totalSeconds: Int
    public let sessionCount: Int
    public let bySubject: [String: Int]

    public var isEmpty: Bool { totalSeconds == 0 }
    public var minutes: Int { totalSeconds / 60 }
}

public enum StudyCalendar {

    /// Which day a session belongs to.
    ///
    /// A session that crosses midnight is attributed **wholly to the day it
    /// started**. Splitting it would be more literally accurate, but it breaks
    /// the streak — study from 23:50 to 00:20 would credit two days for one
    /// sitting, and a student could hold a streak by studying at midnight
    /// every other day.
    ///
    /// This must match whatever the server adopts (LMS-DEV t-d1bea68 §5). It is
    /// isolated here so changing it is a one-line change, not a hunt.
    static func day(of session: StudySession, calendar: Calendar) -> Date {
        calendar.startOfDay(for: session.startedAt)
    }

    /// Daily totals across a range, **including days with no study**.
    ///
    /// The zero days are the point: a calendar that omits them silently
    /// compresses a gap, which is exactly the information a student and a
    /// parent are looking for.
    public static func dailyTotals(
        sessions: [StudySession],
        from: Date,
        to: Date,
        calendar: Calendar = .current,
        asOf now: Date = Date()
    ) -> [DailyStudyTotal] {
        var byDay: [Date: (seconds: Int, count: Int, subjects: [String: Int])] = [:]

        for session in sessions where session.isCountable {
            let key = day(of: session, calendar: calendar)
            let seconds = Int(session.duration(asOf: now))
            var entry = byDay[key] ?? (0, 0, [:])
            entry.seconds += seconds
            entry.count += 1
            entry.subjects[session.subjectName, default: 0] += seconds
            byDay[key] = entry
        }

        var results: [DailyStudyTotal] = []
        var cursor = calendar.startOfDay(for: from)
        let last = calendar.startOfDay(for: to)

        while cursor <= last {
            let entry = byDay[cursor]
            results.append(
                DailyStudyTotal(
                    date: cursor,
                    totalSeconds: entry?.seconds ?? 0,
                    sessionCount: entry?.count ?? 0,
                    bySubject: entry?.subjects ?? [:]
                )
            )
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        return results
    }

    /// Consecutive days of study, counting back from today.
    ///
    /// Today not being studied *yet* does not break a streak — it is still
    /// early. The count runs from yesterday in that case, so a student opening
    /// the app in the morning is not told they have lost anything.
    public static func streak(
        sessions: [StudySession],
        asOf now: Date = Date(),
        calendar: Calendar = .current
    ) -> StudyStreak {
        let studiedDays = Set(
            sessions
                .filter(\.isCountable)
                .map { day(of: $0, calendar: calendar) }
        )

        let today = calendar.startOfDay(for: now)
        let studiedToday = studiedDays.contains(today)

        var cursor = studiedToday ? today : calendar.date(byAdding: .day, value: -1, to: today) ?? today
        var days = 0

        while studiedDays.contains(cursor) {
            days += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }

        return StudyStreak(days: days, studiedToday: studiedToday)
    }

    public static func totalSeconds(
        on date: Date,
        sessions: [StudySession],
        calendar: Calendar = .current,
        asOf now: Date = Date()
    ) -> Int {
        let target = calendar.startOfDay(for: date)
        return sessions
            .filter { $0.isCountable && day(of: $0, calendar: calendar) == target }
            .reduce(0) { $0 + Int($1.duration(asOf: now)) }
    }
}
