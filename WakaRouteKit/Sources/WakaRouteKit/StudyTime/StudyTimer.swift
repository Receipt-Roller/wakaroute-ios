import Foundation

/// Owns the clock and the local session history.
///
/// Offline-first by design: every session is written locally the instant it
/// starts, and uploaded later. A student on a train has no connection, and
/// losing their record because of that would be worse than not having the
/// feature.
public actor StudyTimer {
    /// Beyond this, a still-running session is assumed to be the result of the
    /// app being killed rather than genuine study. Nobody studies one topic for
    /// three hours without touching the phone, and counting it would poison
    /// every average the calendar shows.
    public static let maximumSessionDuration: TimeInterval = 3 * 60 * 60

    private let store: any StudySessionStore
    private let now: @Sendable () -> Date

    private var sessions: [StudySession] = []
    private var loaded = false

    public init(store: any StudySessionStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    // MARK: - Loading

    /// Reads history and resolves anything left running by a previous launch.
    ///
    /// Returns sessions that were still going and are now too old to trust, so
    /// the UI can tell the student rather than silently discarding or silently
    /// counting them.
    @discardableResult
    public func loadHistory() throws -> [StudySession] {
        guard !loaded else { return [] }
        sessions = try store.load()
        loaded = true

        var stale: [StudySession] = []
        for index in sessions.indices where sessions[index].isRunning {
            if sessions[index].duration(asOf: now()) > Self.maximumSessionDuration {
                sessions[index].abandon()
                stale.append(sessions[index])
            }
        }

        if !stale.isEmpty { try store.save(sessions) }
        return stale
    }

    // MARK: - The clock

    public var runningSession: StudySession? {
        sessions.first { $0.isRunning }
    }

    /// Starts the clock. Any session already running is stopped first — two
    /// concurrent timers would double-count the same minutes.
    @discardableResult
    public func start(title: String, subjectName: String, kind: RouteStep.Kind) throws -> StudySession {
        try loadHistory()

        if runningSession != nil {
            _ = try stop()
        }

        let session = StudySession(
            startedAt: now(),
            title: title,
            subjectName: subjectName,
            kind: kind
        )
        sessions.append(session)
        // Persisted immediately: if the app dies now, the start time survives.
        try store.save(sessions)
        return session
    }

    @discardableResult
    public func stop() throws -> StudySession? {
        guard let index = sessions.firstIndex(where: { $0.isRunning }) else { return nil }
        sessions[index].stop(at: now())
        try store.save(sessions)
        return sessions[index]
    }

    /// Drops a running session without recording it — for a mistaken start.
    public func cancelRunning() throws {
        guard let index = sessions.firstIndex(where: { $0.isRunning }) else { return }
        sessions.remove(at: index)
        try store.save(sessions)
    }

    /// Keeps a stale session but trims it to a duration worth recording, for
    /// when the student says they really were studying.
    public func keepStale(id: UUID, duration: TimeInterval) throws {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let start = sessions[index].startedAt
        sessions[index] = StudySession(
            id: sessions[index].id,
            startedAt: start,
            endedAt: start.addingTimeInterval(min(duration, Self.maximumSessionDuration)),
            title: sessions[index].title,
            subjectName: sessions[index].subjectName,
            kind: sessions[index].kind
        )
        try store.save(sessions)
    }

    // MARK: - Reading

    public func allSessions() throws -> [StudySession] {
        try loadHistory()
        return sessions.sorted { $0.startedAt > $1.startedAt }
    }

    public func countableSessions() throws -> [StudySession] {
        try allSessions().filter(\.isCountable)
    }

    /// Sessions not yet accepted by the server, oldest first — the replay queue
    /// for when the study-session API exists.
    public func pendingUpload() throws -> [StudySession] {
        try allSessions()
            .filter { $0.isCountable && !$0.isSynced && !$0.isRejected }
            .reversed()
    }

    /// Sessions the server will never accept. Surfaced so they can be shown as
    /// unsent rather than silently pretended to be uploaded.
    public func rejectedSessions() throws -> [StudySession] {
        try allSessions().filter(\.isRejected)
    }

    /// Stops retrying sessions the server has permanently refused.
    public func markRejected(ids: Set<UUID>) throws {
        for index in sessions.indices where ids.contains(sessions[index].id) {
            sessions[index].markRejected()
        }
        try store.save(sessions)
    }

    /// Wipes the local study history.
    ///
    /// Called when the account is deleted. The sessions live only on this
    /// device until the sync API exists, so leaving them would keep a record of
    /// a student who asked to be forgotten.
    public func deleteAllSessions() throws {
        sessions = []
        loaded = true
        try store.save([])
    }

    public func markSynced(ids: Set<UUID>) throws {
        for index in sessions.indices where ids.contains(sessions[index].id) {
            sessions[index].markSynced()
        }
        try store.save(sessions)
    }
}
