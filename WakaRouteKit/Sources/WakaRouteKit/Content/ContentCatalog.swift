import Foundation

/// One 教科 with its 領域 and the learner's progress across them.
public struct SubjectOverview: Sendable, Equatable, Identifiable {
    public var id: SubjectId { subject.id }
    public let subject: SchoolSubject
    public let paths: [LearningPathSummary]
    public let totalCourses: Int
    public let completedCourses: Int
    /// Courses with at least one finished lesson. Kept apart from
    /// `completedCourses` so a subject someone has begun does not read the same
    /// as one they have not opened.
    public let startedCourses: Int

    /// No paths at all — the subject has not been built yet.
    public var isPlanned: Bool { paths.isEmpty }
    /// Paths exist but hold nothing.
    public var isAwaitingContent: Bool { !paths.isEmpty && totalCourses == 0 }

    public var completedFraction: Double {
        totalCourses == 0 ? 0 : Double(completedCourses) / Double(totalCourses)
    }

    public init(
        subject: SchoolSubject,
        paths: [LearningPathSummary],
        totalCourses: Int,
        completedCourses: Int,
        startedCourses: Int = 0
    ) {
        self.subject = subject
        self.paths = paths
        self.totalCourses = totalCourses
        self.completedCourses = completedCourses
        self.startedCourses = startedCourses
    }
}

/// The learning hierarchy with progress folded in.
///
/// Loads paths and progress together because the two come from different
/// endpoints and a screen showing one without the other is misleading —
/// courses with no progress look untouched rather than unknown.
public struct ContentCatalog: Sendable, Equatable {
    public let subjects: [SubjectOverview]
    /// Paths carrying no recognised 教科 label. Surfaced rather than dropped.
    public let unclassified: [LearningPathSummary]
    public let progressByCourse: [String: CourseProgress]
    /// Which courses sit in which path. Kept so a screen can list a 教科's
    /// courses without a request per path — everything below is already here.
    public let structure: ContentStructure

    /// `structure` says which courses belong to which path. Without it the
    /// progress can still be shown per course but not per 教科, so the subject
    /// counts come back zero — which is why it is passed rather than inferred.
    public init(
        paths: [LearningPathSummary],
        progress: [CourseProgress],
        structure: ContentStructure = ContentStructure()
    ) {
        let byCourse = Dictionary(progress.map { ($0.courseId, $0) }, uniquingKeysWith: { first, _ in first })
        progressByCourse = byCourse
        self.structure = structure
        unclassified = SubjectCatalog.unclassified(paths: paths)

        subjects = SubjectCatalog.group(paths: paths).map { grouped in
            let courseIds = grouped.paths.flatMap { structure.courseIds(inPath: $0.id) }

            return SubjectOverview(
                subject: grouped.subject,
                paths: grouped.paths,
                // courseCount is authoritative even before the courses
                // themselves are fetched, so the count is right on first paint.
                totalCourses: grouped.courseCount,
                completedCourses: courseIds.filter { byCourse[$0]?.isCompleted == true }.count,
                startedCourses: courseIds.filter { (byCourse[$0]?.completedLessons ?? 0) > 0 }.count
            )
        }
    }

    public func progress(forCourse id: String) -> CourseProgress? {
        progressByCourse[id]
    }

    /// One 教科's courses, grouped by 領域 and in the order they should be taken.
    ///
    /// The 領域 becomes a heading rather than a level of navigation. On a wide
    /// screen that removes a whole tap from 教科 → 領域 → コース → レッスン, and
    /// it costs nothing: every id and title here was already fetched.
    public func courseGroups(inSubject id: SubjectId) -> [(path: LearningPathSummary, courses: [ContentStructure.Course])] {
        guard let overview = subjects.first(where: { $0.id == id }) else { return [] }
        return overview.paths.compactMap { path in
            let courses = structure.byPath[path.id]?.courses ?? []
            return courses.isEmpty ? nil : (path, courses)
        }
    }
}
