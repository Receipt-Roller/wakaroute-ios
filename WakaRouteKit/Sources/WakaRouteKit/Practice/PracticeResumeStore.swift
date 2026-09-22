import Foundation

/// A pointer back to a session the student was in the middle of.
///
/// Deliberately **not** a copy of the session: no question, no attempt count,
/// no score. Those live on the server and are read back on resume (start guide
/// §6.3). All this remembers is which session, and under what
/// `clientReference`, so the app can find its way back to it.
public struct PracticeResumePoint: Codable, Sendable, Equatable {
    public let sessionId: String
    /// Kept so a start that failed on the way out can be retried without
    /// opening a second session.
    public let clientReference: String
    public let startedAt: Date

    public init(sessionId: String, clientReference: String, startedAt: Date = Date()) {
        self.sessionId = sessionId
        self.clientReference = clientReference
        self.startedAt = startedAt
    }
}

public protocol PracticeResumeStore: Sendable {
    func load() throws -> PracticeResumePoint?
    func save(_ point: PracticeResumePoint?) throws
}

public struct FilePracticeResumeStore: PracticeResumeStore {
    private let url: URL

    public init(url: URL) { self.url = url }

    public static func inApplicationSupport(fileName: String = "practice-resume.json") throws -> FilePracticeResumeStore {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        return FilePracticeResumeStore(url: directory.appending(path: fileName))
    }

    public func load() throws -> PracticeResumePoint? {
        guard FileManager.default.fileExists(atPath: url.filePath) else { return nil }
        return try JSONDecoder.wakaRoute.decode(PracticeResumePoint.self, from: Data(contentsOf: url))
    }

    public func save(_ point: PracticeResumePoint?) throws {
        guard let point else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try JSONEncoder.wakaRoute.encode(point).write(to: url, options: .atomic)
    }
}

public final class InMemoryPracticeResumeStore: PracticeResumeStore, @unchecked Sendable {
    private let lock = NSLock()
    private var point: PracticeResumePoint?

    public init(point: PracticeResumePoint? = nil) { self.point = point }

    public func load() throws -> PracticeResumePoint? { lock.withLock { point } }
    public func save(_ newPoint: PracticeResumePoint?) throws { lock.withLock { point = newPoint } }
}
