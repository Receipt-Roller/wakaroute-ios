import Foundation

/// Which courses sit in which path.
///
/// MANABU2 has no single call that tells a learner this. `/me/progress` names
/// courses without saying where they belong, `/me/paths` is empty because
/// ワカルート never assigns paths to students, and `/me/assignments` answers with
/// the shared corporate catalogue instead. Building the mapping means one
/// request per path — so it is built once and kept. (LMS-DEV t-d1bea82 asks for
/// a cheaper route; when it lands this whole file can go.)
///
/// Caching this is safe in a way that caching progress would not be: it
/// describes what someone authored, not what a student did.
public struct ContentStructure: Codable, Sendable, Equatable {
    /// A course as the path listed it. The title is carried so the 理解マップ can
    /// name a 要素 without a request per course — it is display text only, never
    /// matched against anything.
    public struct Course: Codable, Sendable, Equatable, Hashable, Identifiable {
        public let id: String
        public let title: String

        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    public struct Entry: Codable, Sendable, Equatable {
        public let courses: [Course]
        /// What the path listing claimed when this was fetched. A later listing
        /// disagreeing means someone added or removed a course, and only that
        /// one path needs fetching again.
        public let courseCount: Int

        public var courseIds: [String] { courses.map(\.id) }

        public init(courses: [Course], courseCount: Int) {
            self.courses = courses
            self.courseCount = courseCount
        }
    }

    public private(set) var byPath: [String: Entry]

    public init(byPath: [String: Entry] = [:]) {
        self.byPath = byPath
    }

    public func courseIds(inPath pathId: String) -> [String] {
        byPath[pathId]?.courseIds ?? []
    }

    public mutating func record(pathId: String, courses: [Course], courseCount: Int) {
        byPath[pathId] = Entry(courses: courses, courseCount: courseCount)
    }

    /// Paths we have never fetched, or whose course count has since changed.
    ///
    /// Comparing against a live listing rather than an expiry time means new
    /// content appears as soon as the listing shows it, instead of whenever a
    /// timer happened to lapse — which matters while the content team is still
    /// adding courses daily.
    public func stalePathIds(against paths: [LearningPathSummary]) -> [String] {
        paths
            .filter { byPath[$0.id]?.courseCount != $0.courseCount }
            .map(\.id)
    }

    /// Course id → path id. Built once per read rather than stored, so the
    /// on-disk form stays the one shape.
    public var pathIdByCourse: [String: String] {
        var result: [String: String] = [:]
        for (pathId, entry) in byPath {
            for courseId in entry.courseIds {
                result[courseId] = pathId
            }
        }
        return result
    }
}

public protocol ContentStructureStore: Sendable {
    func load() throws -> ContentStructure
    func save(_ structure: ContentStructure) throws
}

public struct FileContentStructureStore: ContentStructureStore {
    private let url: URL

    public init(url: URL) { self.url = url }

    public static func inApplicationSupport(
        fileName: String = "content-structure.json"
    ) throws -> FileContentStructureStore {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        return FileContentStructureStore(url: directory.appending(path: fileName))
    }

    public func load() throws -> ContentStructure {
        guard FileManager.default.fileExists(atPath: url.filePath) else { return ContentStructure() }
        return try JSONDecoder.wakaRoute.decode(ContentStructure.self, from: Data(contentsOf: url))
    }

    public func save(_ structure: ContentStructure) throws {
        try JSONEncoder.wakaRoute.encode(structure).write(to: url, options: .atomic)
    }
}

public final class InMemoryContentStructureStore: ContentStructureStore, @unchecked Sendable {
    private let lock = NSLock()
    private var structure: ContentStructure

    public init(structure: ContentStructure = ContentStructure()) {
        self.structure = structure
    }

    public func load() throws -> ContentStructure { lock.withLock { structure } }
    public func save(_ new: ContentStructure) throws { lock.withLock { structure = new } }
}

/// Keeps the mapping current, fetching only the paths that changed.
public actor ContentStructureCache {
    private let store: any ContentStructureStore
    private let content: ContentClient
    private var structure: ContentStructure?

    public init(store: any ContentStructureStore, content: ContentClient) {
        self.store = store
        self.content = content
    }

    /// The mapping, refreshed against the given listing.
    ///
    /// A path that cannot be fetched keeps whatever we already had rather than
    /// disappearing: a stale course list still puts most courses in the right
    /// subject, and an empty one puts every course nowhere.
    public func structure(refreshedAgainst paths: [LearningPathSummary]) async -> ContentStructure {
        var current = structure ?? (try? store.load()) ?? ContentStructure()

        let stale = current.stalePathIds(against: paths)
        guard !stale.isEmpty else {
            structure = current
            return current
        }

        let counts = Dictionary(paths.map { ($0.id, $0.courseCount) }, uniquingKeysWith: { first, _ in first })

        // Sequential rather than parallel: this runs behind an already-usable
        // screen, and twenty simultaneous requests from every new install is a
        // worse neighbour than twenty spread over a second.
        for pathId in stale {
            guard let detail = try? await content.path(id: pathId) else { continue }
            current.record(
                pathId: pathId,
                courses: detail.courses.map { ContentStructure.Course(id: $0.id, title: $0.title) },
                courseCount: counts[pathId] ?? detail.courses.count
            )
        }

        structure = current
        try? store.save(current)
        return current
    }

    /// What is already known, without touching the network.
    public func cached() -> ContentStructure {
        let current = structure ?? (try? store.load()) ?? ContentStructure()
        structure = current
        return current
    }
}
