import Foundation
import Testing
@testable import WakaRouteKit

private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

private let jst: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = tokyo
    return calendar
}()

private func at(_ iso: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = tokyo
    return formatter.date(from: iso)!
}

/// A clock the test drives, so elapsed time can be simulated without waiting.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) { current = start }

    var now: Date { lock.withLock { current } }
    func advance(_ interval: TimeInterval) { lock.withLock { current += interval } }
    func set(_ date: Date) { lock.withLock { current = date } }
}

private func session(
    _ start: String,
    minutes: Int?,
    subject: String = "数学",
    title: String = "学習",
    abandoned: Bool = false
) -> StudySession {
    StudySession(
        startedAt: at(start),
        endedAt: minutes.map { at(start).addingTimeInterval(TimeInterval($0 * 60)) },
        title: title,
        subjectName: subject,
        kind: .practice,
        isAbandoned: abandoned
    )
}

@Suite("Study timer")
struct StudyTimerTests {

    @Test("Starting and stopping records the elapsed time")
    func recordsElapsedTime() async throws {
        let clock = TestClock(at("2026-08-02T20:00:00+09:00"))
        let timer = StudyTimer(store: InMemoryStudySessionStore(), now: { clock.now })

        try await timer.start(title: "文字式の練習", subjectName: "数学", kind: .practice)
        clock.advance(12 * 60)
        let stopped = try #require(try await timer.stop())

        #expect(stopped.duration(asOf: clock.now) == 720)
        #expect(stopped.isCountable)
    }

    /// Elapsed time is measured against the wall clock, so a session continues
    /// to count while the app is suspended or the screen is locked.
    @Test("Time passes while the app is backgrounded")
    func countsWhileBackgrounded() async throws {
        let clock = TestClock(at("2026-08-02T20:00:00+09:00"))
        let timer = StudyTimer(store: InMemoryStudySessionStore(), now: { clock.now })

        try await timer.start(title: "復習", subjectName: "数学", kind: .review)
        clock.advance(20 * 60)          // phone in a pocket, no ticks delivered

        let running = try #require(await timer.runningSession)
        #expect(running.duration(asOf: clock.now) == 1200)
    }

    /// The start is written to disk immediately, so a termination mid-session
    /// loses the end time but never the fact that study happened.
    @Test("A running session survives app termination")
    func survivesTermination() async throws {
        let store = InMemoryStudySessionStore()
        let clock = TestClock(at("2026-08-02T20:00:00+09:00"))

        let first = StudyTimer(store: store, now: { clock.now })
        try await first.start(title: "文字式の練習", subjectName: "数学", kind: .practice)

        // App is killed. A fresh timer reads the same store.
        clock.advance(15 * 60)
        let second = StudyTimer(store: store, now: { clock.now })
        try await second.loadHistory()

        let recovered = try #require(await second.runningSession)
        #expect(recovered.title == "文字式の練習")
        #expect(recovered.duration(asOf: clock.now) == 900)
    }

    /// A session found running hours later means the app died, not that a
    /// student studied one topic all evening. Counting it would distort every
    /// average on the calendar.
    @Test("A session left running too long is abandoned, not counted")
    func abandonsRunawaySession() async throws {
        let store = InMemoryStudySessionStore()
        let clock = TestClock(at("2026-08-02T20:00:00+09:00"))

        let first = StudyTimer(store: store, now: { clock.now })
        try await first.start(title: "練習", subjectName: "数学", kind: .practice)

        clock.advance(9 * 60 * 60)      // battery died, next launch is next morning
        let second = StudyTimer(store: store, now: { clock.now })
        let stale = try await second.loadHistory()

        #expect(stale.count == 1)
        let countable = try await second.countableSessions()
        #expect(countable.isEmpty)
        #expect(await second.runningSession == nil)
    }

    @Test("A stale session can be kept at a duration the student confirms")
    func staleSessionCanBeKept() async throws {
        let store = InMemoryStudySessionStore()
        let clock = TestClock(at("2026-08-02T20:00:00+09:00"))

        let first = StudyTimer(store: store, now: { clock.now })
        try await first.start(title: "練習", subjectName: "数学", kind: .practice)
        clock.advance(9 * 60 * 60)

        let second = StudyTimer(store: store, now: { clock.now })
        let stale = try await second.loadHistory()
        try await second.keepStale(id: try #require(stale.first).id, duration: 25 * 60)

        let kept = try #require(try await second.countableSessions().first)
        #expect(kept.duration(asOf: clock.now) == 1500)
    }

    @Test("Starting a second timer stops the first rather than double-counting")
    func onlyOneTimerRuns() async throws {
        let clock = TestClock(at("2026-08-02T20:00:00+09:00"))
        let timer = StudyTimer(store: InMemoryStudySessionStore(), now: { clock.now })

        try await timer.start(title: "数学", subjectName: "数学", kind: .learn)
        clock.advance(5 * 60)
        try await timer.start(title: "英語", subjectName: "英語", kind: .learn)

        let all = try await timer.allSessions()
        #expect(all.filter(\.isRunning).count == 1)
        #expect(try await timer.countableSessions().count == 1)
    }

    @Test("A cancelled session leaves no trace")
    func cancelDiscards() async throws {
        let clock = TestClock(at("2026-08-02T20:00:00+09:00"))
        let timer = StudyTimer(store: InMemoryStudySessionStore(), now: { clock.now })

        try await timer.start(title: "誤操作", subjectName: "数学", kind: .learn)
        try await timer.cancelRunning()

        #expect(try await timer.allSessions().isEmpty)
    }

    @Test("Unsynced sessions queue oldest-first for replay")
    func pendingUploadIsOldestFirst() async throws {
        let store = InMemoryStudySessionStore(sessions: [
            session("2026-08-01T20:00:00+09:00", minutes: 10),
            session("2026-08-02T20:00:00+09:00", minutes: 10)
        ])
        let timer = StudyTimer(store: store, now: { at("2026-08-02T22:00:00+09:00") })

        let pending = try await timer.pendingUpload()
        #expect(pending.count == 2)
        #expect(pending.first!.startedAt < pending.last!.startedAt)
    }
}

@Suite("Study calendar")
struct StudyCalendarTests {

    @Test("Daily totals include days with no study")
    func seriesIsDense() {
        let totals = StudyCalendar.dailyTotals(
            sessions: [session("2026-08-01T20:00:00+09:00", minutes: 30)],
            from: at("2026-08-01T00:00:00+09:00"),
            to: at("2026-08-05T00:00:00+09:00"),
            calendar: jst,
            asOf: at("2026-08-05T23:00:00+09:00")
        )

        #expect(totals.count == 5)
        #expect(totals[0].totalSeconds == 1800)
        let laterDays = totals.dropFirst()
        #expect(laterDays.allSatisfy { $0.isEmpty })
    }

    /// A late-night session belongs to the day it started, so the streak counts
    /// one sitting once rather than crediting two days.
    @Test("A session crossing midnight counts on its start date only")
    func midnightBelongsToStartDate() {
        let totals = StudyCalendar.dailyTotals(
            sessions: [session("2026-08-02T23:40:00+09:00", minutes: 40)],
            from: at("2026-08-02T00:00:00+09:00"),
            to: at("2026-08-03T00:00:00+09:00"),
            calendar: jst,
            asOf: at("2026-08-03T09:00:00+09:00")
        )

        #expect(totals[0].totalSeconds == 2400, "All 40 minutes land on 8/2…")
        #expect(totals[1].isEmpty, "…and none on 8/3.")
    }

    @Test("Totals split by subject")
    func splitsBySubject() {
        let totals = StudyCalendar.dailyTotals(
            sessions: [
                session("2026-08-02T19:00:00+09:00", minutes: 20, subject: "数学"),
                session("2026-08-02T20:00:00+09:00", minutes: 11, subject: "英語")
            ],
            from: at("2026-08-02T00:00:00+09:00"),
            to: at("2026-08-02T00:00:00+09:00"),
            calendar: jst,
            asOf: at("2026-08-02T23:00:00+09:00")
        )

        #expect(totals[0].bySubject["数学"] == 1200)
        #expect(totals[0].bySubject["英語"] == 660)
        #expect(totals[0].sessionCount == 2)
    }

    @Test("Abandoned and still-running sessions are excluded")
    func excludesUncountableSessions() {
        let totals = StudyCalendar.dailyTotals(
            sessions: [
                session("2026-08-02T19:00:00+09:00", minutes: nil),             // running
                session("2026-08-02T10:00:00+09:00", minutes: 60, abandoned: true)
            ],
            from: at("2026-08-02T00:00:00+09:00"),
            to: at("2026-08-02T00:00:00+09:00"),
            calendar: jst,
            asOf: at("2026-08-02T20:00:00+09:00")
        )

        #expect(totals[0].isEmpty)
    }

    @Test("Consecutive days build a streak")
    func countsConsecutiveDays() {
        let streak = StudyCalendar.streak(
            sessions: [
                session("2026-07-31T20:00:00+09:00", minutes: 10),
                session("2026-08-01T20:00:00+09:00", minutes: 10),
                session("2026-08-02T20:00:00+09:00", minutes: 10)
            ],
            asOf: at("2026-08-02T21:00:00+09:00"),
            calendar: jst
        )

        #expect(streak.days == 3)
        #expect(streak.studiedToday)
    }

    /// Opening the app before studying must not report the streak as lost.
    @Test("Not having studied yet today does not break the streak")
    func morningDoesNotBreakStreak() {
        let streak = StudyCalendar.streak(
            sessions: [
                session("2026-08-01T20:00:00+09:00", minutes: 10),
                session("2026-08-02T20:00:00+09:00", minutes: 10)
            ],
            asOf: at("2026-08-03T07:00:00+09:00"),
            calendar: jst
        )

        #expect(streak.days == 2)
        #expect(streak.studiedToday == false)
    }

    @Test("A missed day ends the streak")
    func gapEndsStreak() {
        let streak = StudyCalendar.streak(
            sessions: [
                session("2026-07-28T20:00:00+09:00", minutes: 10),
                session("2026-08-02T20:00:00+09:00", minutes: 10)
            ],
            asOf: at("2026-08-02T21:00:00+09:00"),
            calendar: jst
        )

        #expect(streak.days == 1)
    }

    @Test("No history is a zero streak, not a crash")
    func emptyHistoryIsSafe() {
        let streak = StudyCalendar.streak(sessions: [], asOf: at("2026-08-02T21:00:00+09:00"), calendar: jst)

        #expect(streak.days == 0)
        #expect(streak.studiedToday == false)
    }

    /// 23:50 and 00:10 are different days in Tokyo, and students study late.
    @Test("Day boundaries follow the Tokyo calendar, not 24-hour windows")
    func dayBoundariesAreCalendarDays() {
        let sessions = [
            session("2026-08-02T23:50:00+09:00", minutes: 5),
            session("2026-08-03T00:10:00+09:00", minutes: 5)
        ]

        #expect(StudyCalendar.totalSeconds(on: at("2026-08-02T12:00:00+09:00"), sessions: sessions, calendar: jst) == 300)
        #expect(StudyCalendar.totalSeconds(on: at("2026-08-03T12:00:00+09:00"), sessions: sessions, calendar: jst) == 300)
    }
}
