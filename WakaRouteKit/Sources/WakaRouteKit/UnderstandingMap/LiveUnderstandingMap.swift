import Foundation

/// The 理解マップ built from published content and the learner's own record.
///
/// Only 数学 today: its 26 要素 exist as MANABU2 courses with stable ids, and
/// its prerequisite edges have been authored (t-1fa7220). The other four
/// subjects report `unavailable` until theirs are, rather than being given an
/// empty graph — a subject with no edges would show every 要素 as ready to study
/// and never send a student back to anything, which reads as "you have no gaps"
/// and is the one wrong answer this map must not give.
public actor LiveUnderstandingMapRepository: UnderstandingMapRepository {
    private let content: ContentClient
    private let structureCache: ContentStructureCache

    /// Loaded once. The graph is authored data, not a student's record, so it
    /// cannot go stale within a session.
    private var graph: PrerequisiteGraph?
    private var cachedSubjects: [Subject]?
    private var cachedRecord: MasteryRecord?

    public init(content: ContentClient, structureCache: ContentStructureCache) {
        self.content = content
        self.structureCache = structureCache
    }

    /// Hands over progress a caller has already fetched.
    ///
    /// The dashboard loads `/me/progress` and `/me/quiz-attempts` for its own
    /// sections, and the map needs exactly those two. Priming it means the map
    /// costs nothing on that screen; without it the repository fetches for
    /// itself, so screens opened on their own still work.
    public func use(progress: [CourseProgress], quizAttempts: [QuizAttempt]) {
        cachedRecord = MasteryDerivation.record(progress: progress, quizAttempts: quizAttempts)
    }

    private static let unavailable = "この教科の理解マップは準備中です。"

    public func subjects() async throws -> MapAvailability<[Subject]> {
        if let cachedSubjects { return .available(cachedSubjects) }

        guard let graph = try? loadedGraph() else {
            return .unavailable(reason: Self.unavailable)
        }

        // Live titles, so a renamed course shows its new name. The graph's own
        // titles exist for review and diagnostics, never for display when the
        // real one is available.
        let titles = await structureCache.cached().titlesByCourseId
        let subject = graph.subject(id: SchoolSubject.math.id, titlesByCourseId: titles)

        cachedSubjects = [subject]
        return .available([subject])
    }

    public func mastery(for subjectId: SubjectId) async throws -> MapAvailability<MasteryRecord> {
        guard subjectId == SchoolSubject.math.id else {
            return .unavailable(reason: Self.unavailable)
        }
        if let cachedRecord { return .available(cachedRecord) }

        // The same two responses the dashboard already loads, so the map costs
        // no extra requests on a screen that also shows progress.
        let progress = (try? await content.myProgress()) ?? []
        let attempts = (try? await content.quizAttempts(
            from: ActivityTimeline.dateParameter(
                Calendar.current.date(byAdding: .day, value: -365, to: Date()) ?? Date()
            ),
            to: ActivityTimeline.dateParameter(Date())
        )) ?? []

        let record = MasteryDerivation.record(progress: progress, quizAttempts: attempts)
        cachedRecord = record
        return .available(record)
    }

    /// Reads and checks the graph once.
    ///
    /// A graph with a cycle or a dangling edge is refused outright rather than
    /// partly applied: half a prerequisite graph sends students back to the
    /// wrong place, which is worse than showing no map at all. Since the graph
    /// ships in the bundle, this can only fail if it was edited badly — which is
    /// what `PrerequisiteGraphTests` exists to catch before a build goes out.
    private func loadedGraph() throws -> PrerequisiteGraph {
        if let graph { return graph }

        let loaded = try PrerequisiteGraph.math()
        let problems = loaded.problems()
        guard problems.isEmpty else {
            throw PrerequisiteGraph.GraphError.invalid(problems: problems)
        }

        graph = loaded
        return loaded
    }
}

extension ContentStructure {
    /// Course id → its published title.
    public var titlesByCourseId: [String: String] {
        var result: [String: String] = [:]
        for entry in byPath.values {
            for course in entry.courses {
                result[course.id] = course.title
            }
        }
        return result
    }
}
