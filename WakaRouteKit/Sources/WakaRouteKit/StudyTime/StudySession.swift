import Foundation

/// One stretch of study, from starting the clock to stopping it.
///
/// Elapsed time is always derived from `startedAt` against the wall clock,
/// never accumulated by a ticking counter. A counter stops when the app is
/// suspended, so a student who locks the screen for twenty minutes would be
/// credited with nothing.
public struct StudySession: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let startedAt: Date
    public private(set) var endedAt: Date?
    /// What was being studied. Free text today; becomes a MANABU2 course id
    /// once the 理解マップ mapping lands.
    public let title: String
    public let subjectName: String
    public let kind: RouteStep.Kind
    /// Set when a session was found still running long past any plausible
    /// study period — the app was killed or the battery died. Excluded from
    /// totals rather than silently counted.
    public private(set) var isAbandoned: Bool
    /// Cleared once the server has accepted this session.
    public private(set) var isSynced: Bool
    /// The server refused this session outright and always will — a malformed
    /// timestamp, for instance. Kept locally so the student does not lose their
    /// own record, but never retried, because a permanently rejected session
    /// at the head of the queue would block everything behind it forever.
    public private(set) var isRejected: Bool

    public init(
        id: UUID = UUID(),
        startedAt: Date,
        endedAt: Date? = nil,
        title: String,
        subjectName: String,
        kind: RouteStep.Kind,
        isAbandoned: Bool = false,
        isSynced: Bool = false,
        isRejected: Bool = false
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.title = title
        self.subjectName = subjectName
        self.kind = kind
        self.isAbandoned = isAbandoned
        self.isSynced = isSynced
        self.isRejected = isRejected
    }

    private enum CodingKeys: String, CodingKey {
        case id, startedAt, endedAt, title, subjectName, kind, isAbandoned, isSynced, isRejected
    }

    /// Decoded field by field rather than synthesised.
    ///
    /// Files written by earlier versions do not contain every flag, and a
    /// synthesised decoder would throw on the whole array — losing a student's
    /// entire study history because one boolean was added later. Missing flags
    /// default to false.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        subjectName = try c.decodeIfPresent(String.self, forKey: .subjectName) ?? ""
        kind = try c.decodeIfPresent(RouteStep.Kind.self, forKey: .kind) ?? .practice
        isAbandoned = try c.decodeIfPresent(Bool.self, forKey: .isAbandoned) ?? false
        isSynced = try c.decodeIfPresent(Bool.self, forKey: .isSynced) ?? false
        isRejected = try c.decodeIfPresent(Bool.self, forKey: .isRejected) ?? false
    }

    public var isRunning: Bool { endedAt == nil && !isAbandoned }

    /// How long this ran. For a session still going, measured against `now`.
    public func duration(asOf now: Date) -> TimeInterval {
        guard !isAbandoned else { return 0 }
        return max(0, (endedAt ?? now).timeIntervalSince(startedAt))
    }

    /// Whether this counts toward totals.
    public var isCountable: Bool { endedAt != nil && !isAbandoned }

    mutating func stop(at date: Date) {
        endedAt = max(date, startedAt)
    }

    mutating func abandon() {
        isAbandoned = true
        endedAt = nil
    }

    public mutating func markSynced() {
        isSynced = true
    }

    public mutating func markRejected() {
        isRejected = true
    }
}

/// Where sessions live between launches.
public protocol StudySessionStore: Sendable {
    func load() throws -> [StudySession]
    func save(_ sessions: [StudySession]) throws
}

/// JSON on disk.
///
/// A running session is written the moment it starts, not when it stops, so a
/// termination mid-session loses nothing but the end time.
public struct FileStudySessionStore: StudySessionStore {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static func inApplicationSupport(fileName: String = "study-sessions.json") throws -> FileStudySessionStore {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return FileStudySessionStore(url: directory.appending(path: fileName))
    }

    public func load() throws -> [StudySession] {
        guard FileManager.default.fileExists(atPath: url.filePath) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder.wakaRoute.decode([StudySession].self, from: data)
    }

    public func save(_ sessions: [StudySession]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Atomic, so a crash mid-write cannot leave a truncated file that would
        // lose every recorded session.
        try encoder.encode(sessions).write(to: url, options: .atomic)
    }
}

public final class InMemoryStudySessionStore: StudySessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [StudySession] = []

    public init(sessions: [StudySession] = []) {
        self.sessions = sessions
    }

    public func load() throws -> [StudySession] {
        lock.withLock { sessions }
    }

    public func save(_ newSessions: [StudySession]) throws {
        lock.withLock { sessions = newSessions }
    }
}
