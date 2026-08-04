import Foundation
import Observation
import WakaRouteKit

@MainActor
@Observable
final class StudyRecordViewModel {
    private(set) var running: StudySession?
    private(set) var sessions: [StudySession] = []
    private(set) var streak = StudyStreak(days: 0, studiedToday: false)
    private(set) var monthTotals: [DailyStudyTotal] = []
    /// A session found still running from a previous launch, too old to trust.
    /// Surfaced so the student decides, rather than being silently discarded.
    private(set) var staleSession: StudySession?

    /// Redrawn once a second only while the clock is running.
    private(set) var tick = Date()

    var visibleMonth = Date()

    private let timer: StudyTimer
    private let sync: StudySync?
    private var ticker: Task<Void, Never>?

    /// How many finished sessions are still only on this device.
    private(set) var pendingUploadCount = 0

    private let content: ContentClient?

    init(timer: StudyTimer, sync: StudySync? = nil, content: ContentClient? = nil) {
        self.timer = timer
        self.sync = sync
        self.content = content
    }

    /// Handed to the history screen, which merges local sessions with the
    /// server's lesson and quiz records. Nil when the app was built without a
    /// content client, in which case the link is simply not offered.
    var historyDependencies: (timer: StudyTimer, content: ContentClient)? {
        content.map { (timer, $0) }
    }

    // No deinit cancelling the ticker: it captures self weakly and returns on
    // the next tick once this object is gone, so it cannot outlive the screen.

    func load() async {
        do {
            let stale = try await timer.loadHistory()
            staleSession = stale.first
            await refresh()
            // Drain the queue after the screen is already usable — a slow or
            // failed upload must never delay showing the student their record.
            await uploadPending()
        } catch {
            // A read failure must not take the screen down; the student simply
            // sees no history until the next launch.
            logger.error("Could not load study history.")
        }
    }

    func start(title: String, subjectName: String, kind: RouteStep.Kind) async {
        try? await timer.start(title: title, subjectName: subjectName, kind: kind)
        await refresh()
    }

    func stop() async {
        try? await timer.stop()
        await refresh()
        // A finished session is worth sending straight away, while the app is
        // in the foreground and the network is most likely available.
        await uploadPending()
    }

    /// Sends anything still queued. Failures are silent by design: the sessions
    /// stay queued, the count stays visible, and the next attempt picks them up.
    func uploadPending() async {
        guard let sync else { return }
        _ = await sync.run()
        await refresh()
    }

    func cancel() async {
        try? await timer.cancelRunning()
        await refresh()
    }

    func keepStale(minutes: Int) async {
        guard let staleSession else { return }
        try? await timer.keepStale(id: staleSession.id, duration: TimeInterval(minutes * 60))
        self.staleSession = nil
        await refresh()
    }

    func discardStale() {
        staleSession = nil
    }

    func changeMonth(by months: Int) {
        guard let moved = Calendar.current.date(byAdding: .month, value: months, to: visibleMonth) else { return }
        visibleMonth = moved
        recomputeMonth()
    }

    // MARK: - Internals

    private func refresh() async {
        sessions = (try? await timer.allSessions()) ?? []
        running = await timer.runningSession
        pendingUploadCount = ((try? await timer.pendingUpload()) ?? []).count
        streak = StudyCalendar.streak(sessions: sessions)
        recomputeMonth()
        updateTicker()
    }

    private func recomputeMonth() {
        let calendar = Calendar.current
        guard
            let interval = calendar.dateInterval(of: .month, for: visibleMonth),
            let last = calendar.date(byAdding: .day, value: -1, to: interval.end)
        else { return }

        monthTotals = StudyCalendar.dailyTotals(
            sessions: sessions,
            from: interval.start,
            to: last
        )
    }

    /// Only runs while a session is active. A permanent timer would redraw the
    /// screen once a second forever and drain the battery for nothing.
    private func updateTicker() {
        ticker?.cancel()
        guard running != nil else { return }

        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                await MainActor.run { self.tick = Date() }
            }
        }
    }
}
