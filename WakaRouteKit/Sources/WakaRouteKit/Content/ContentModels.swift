import Foundation

/// A MANABU2 Path — one 領域 in ワカルート terms, e.g. 数学・数と式.
public struct LearningPathSummary: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let description: String?
    /// 教科 first, 領域 second, by convention. The **only** supported way to
    /// tell which subject a path belongs to — never parse `name`.
    public let labels: [String]
    public let courseCount: Int

    private enum CodingKeys: String, CodingKey { case id, name, description, labels, courseCount }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        labels = try c.decodeIfPresent([String].self, forKey: .labels) ?? []
        courseCount = try c.decodeIfPresent(FlexibleInt.self, forKey: .courseCount)?.value ?? 0
    }

    public init(id: String, name: String, description: String? = nil, labels: [String] = [], courseCount: Int = 0) {
        self.id = id
        self.name = name
        self.description = description
        self.labels = labels
        self.courseCount = courseCount
    }
}

public struct LearningPathDetail: Decodable, Sendable, Equatable {
    public let id: String
    public let name: String

    /// **Do not read this to determine 教科.**
    ///
    /// `GET /api/v1/paths/{id}` never assigns labels — confirmed on LMS-DEV
    /// t-d1bea77 — so this is always `[]` regardless of what the path actually
    /// carries. Its `courseCount` is correct, which makes the gap easy to miss:
    /// fetching detail per path looks like a workaround for the broken list
    /// endpoint, and silently loses the subject.
    ///
    /// 教科 comes from `ContentClient.paths()` and nowhere else.
    public let labels: [String]
    public let courses: [CourseSummary]

    private enum CodingKeys: String, CodingKey { case id, name, labels, courses }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        labels = try c.decodeIfPresent([String].self, forKey: .labels) ?? []
        courses = try c.decodeIfPresent([CourseSummary].self, forKey: .courses) ?? []
    }
}

/// A Course — one 要素, e.g. 文字を用いた式.
public struct CourseSummary: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let description: String?
    public let estimatedMinutes: Int?
    public let lessonCount: Int
    public let sectionCount: Int

    private enum CodingKeys: String, CodingKey {
        case id, title, description, estimatedMinutes, lessonCount, sectionCount
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        estimatedMinutes = try c.decodeIfPresent(FlexibleInt.self, forKey: .estimatedMinutes)?.value
        lessonCount = try c.decodeIfPresent(FlexibleInt.self, forKey: .lessonCount)?.value ?? 0
        sectionCount = try c.decodeIfPresent(FlexibleInt.self, forKey: .sectionCount)?.value ?? 0
    }

    public init(id: String, title: String, description: String? = nil, estimatedMinutes: Int? = nil, lessonCount: Int = 0, sectionCount: Int = 0) {
        self.id = id
        self.title = title
        self.description = description
        self.estimatedMinutes = estimatedMinutes
        self.lessonCount = lessonCount
        self.sectionCount = sectionCount
    }
}

public struct CourseDetail: Decodable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let description: String?
    public let sections: [CourseSection]

    private enum CodingKeys: String, CodingKey { case id, title, description, sections }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        sections = try c.decodeIfPresent([CourseSection].self, forKey: .sections) ?? []
    }

    /// Every lesson in the course, in reading order.
    public var lessons: [LessonSummary] {
        sections.sorted { $0.orderIndex < $1.orderIndex }
            .flatMap { $0.lessons.sorted { $0.orderIndex < $1.orderIndex } }
    }
}

public struct CourseSection: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let summary: String?
    public let orderIndex: Int
    public let lessons: [LessonSummary]

    private enum CodingKeys: String, CodingKey { case id, title, summary, orderIndex, lessons }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        orderIndex = try c.decodeIfPresent(FlexibleInt.self, forKey: .orderIndex)?.value ?? 0
        lessons = try c.decodeIfPresent([LessonSummary].self, forKey: .lessons) ?? []
    }
}

public struct LessonSummary: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let sectionId: String?
    public let title: String
    public let summary: String?
    public let orderIndex: Int
    public let hasVideo: Bool
    public let hasSlides: Bool
    public let hasQuiz: Bool

    private enum CodingKeys: String, CodingKey {
        case id, sectionId, title, summary, orderIndex, hasVideo, hasSlides, hasQuiz
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sectionId = try c.decodeIfPresent(String.self, forKey: .sectionId)
        title = try c.decode(String.self, forKey: .title)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        orderIndex = try c.decodeIfPresent(FlexibleInt.self, forKey: .orderIndex)?.value ?? 0
        hasVideo = try c.decodeIfPresent(Bool.self, forKey: .hasVideo) ?? false
        hasSlides = try c.decodeIfPresent(Bool.self, forKey: .hasSlides) ?? false
        hasQuiz = try c.decodeIfPresent(Bool.self, forKey: .hasQuiz) ?? false
    }
}

extension LessonSummary {
    /// A stand-in carrying only an id, for opening a lesson by id before its
    /// summary has been fetched.
    public static func placeholder(id: String, title: String = "レッスン") -> LessonSummary {
        let json = #"{"id":"\#(id)","title":"\#(title)","orderIndex":0}"#
        // Safe: the literal always satisfies the decoder's requirements.
        return try! JSONDecoder().decode(LessonSummary.self, from: Data(json.utf8))
    }
}

public struct LessonDetail: Decodable, Sendable, Equatable {
    public let id: String
    public let courseId: String?
    public let title: String
    public let summary: String?
    public let bodyHtml: String?
    public let videoUrl: String?
    public let slidesEmbedUrl: String?
    /// The 確認クイズ, delivered with the lesson rather than fetched separately.
    public let quiz: LessonQuiz?

    private enum CodingKeys: String, CodingKey {
        case id, courseId, title, summary, bodyHtml, videoUrl, slidesEmbedUrl, quiz
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        courseId = try c.decodeIfPresent(String.self, forKey: .courseId)
        title = try c.decode(String.self, forKey: .title)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        bodyHtml = try c.decodeIfPresent(String.self, forKey: .bodyHtml)
        videoUrl = try c.decodeIfPresent(String.self, forKey: .videoUrl)
        slidesEmbedUrl = try c.decodeIfPresent(String.self, forKey: .slidesEmbedUrl)
        quiz = try c.decodeIfPresent(LessonQuiz.self, forKey: .quiz)
    }
}

/// Per-course progress from `GET /api/v1/me/progress`.
public struct CourseProgress: Decodable, Sendable, Equatable, Identifiable {
    public var id: String { courseId }
    public let courseId: String
    public let courseTitle: String?
    public let totalLessons: Int
    public let completedLessons: Int
    public let percentComplete: Int
    public let isCompleted: Bool
    /// When this course was last worked on. The only ordering the server gives
    /// for "where was I?", and present on the listing as well as the detail.
    public let lastActivityAt: Date?

    /// Present only on the single-course endpoint, which returns
    /// `CourseProgressDetailDto`. Empty from the overview listing.
    public let lessons: [LessonProgress]

    private enum CodingKeys: String, CodingKey {
        case courseId, courseTitle, totalLessons, completedLessons, percentComplete, isCompleted
        case lastActivityAt, lessons
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        courseId = try c.decode(String.self, forKey: .courseId)
        courseTitle = try c.decodeIfPresent(String.self, forKey: .courseTitle)
        totalLessons = try c.decodeIfPresent(FlexibleInt.self, forKey: .totalLessons)?.value ?? 0
        completedLessons = try c.decodeIfPresent(FlexibleInt.self, forKey: .completedLessons)?.value ?? 0
        percentComplete = try c.decodeIfPresent(FlexibleInt.self, forKey: .percentComplete)?.value ?? 0
        isCompleted = try c.decodeIfPresent(Bool.self, forKey: .isCompleted) ?? false
        lastActivityAt = try c.decodeIfPresent(Date.self, forKey: .lastActivityAt)
        lessons = try c.decodeIfPresent([LessonProgress].self, forKey: .lessons) ?? []
    }

    public func isLessonComplete(_ lessonId: String) -> Bool {
        lesson(lessonId)?.isCompleted ?? false
    }

    public func lesson(_ lessonId: String) -> LessonProgress? {
        lessons.first { $0.lessonId == lessonId }
    }

    /// Completed lessons, most recently finished first — the learning history
    /// for this course.
    public var completionHistory: [LessonProgress] {
        lessons
            .filter { $0.isCompleted && $0.completedAt != nil }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    public init(courseId: String, courseTitle: String? = nil, totalLessons: Int, completedLessons: Int, percentComplete: Int, isCompleted: Bool, lastActivityAt: Date? = nil, lessons: [LessonProgress] = []) {
        self.courseId = courseId
        self.courseTitle = courseTitle
        self.totalLessons = totalLessons
        self.completedLessons = completedLessons
        self.percentComplete = percentComplete
        self.isCompleted = isCompleted
        self.lastActivityAt = lastActivityAt
        self.lessons = lessons
    }
}

/// One lesson's completion, from `GET /api/v1/me/progress/{courseId}`.
///
/// The timestamps are what make this a history rather than a checklist — they
/// are the only record of *when* a student studied something, and the server
/// keeps them, so the app should never need to store its own copy.
public struct LessonProgress: Decodable, Sendable, Equatable, Identifiable {
    public var id: String { lessonId }
    public let lessonId: String
    public let sectionId: String?
    public let title: String?
    public let isViewed: Bool
    public let isCompleted: Bool
    public let viewedAt: Date?
    public let completedAt: Date?

    /// The most recent quiz result for this lesson. All three are nil when the
    /// lesson has no quiz, or has one the student has not sat.
    public let latestQuizScorePercent: Int?
    public let latestQuizPassed: Bool?
    public let latestQuizCompletedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case lessonId, sectionId, title, isViewed, isCompleted, viewedAt, completedAt
        case latestQuizScorePercent, latestQuizPassed, latestQuizCompletedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lessonId = try c.decode(String.self, forKey: .lessonId)
        sectionId = try c.decodeIfPresent(String.self, forKey: .sectionId)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        isViewed = try c.decodeIfPresent(Bool.self, forKey: .isViewed) ?? false
        isCompleted = try c.decodeIfPresent(Bool.self, forKey: .isCompleted) ?? false
        viewedAt = try c.decodeIfPresent(Date.self, forKey: .viewedAt)
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        latestQuizScorePercent = try c.decodeIfPresent(FlexibleInt.self, forKey: .latestQuizScorePercent)?.value
        latestQuizPassed = try c.decodeIfPresent(Bool.self, forKey: .latestQuizPassed)
        latestQuizCompletedAt = try c.decodeIfPresent(Date.self, forKey: .latestQuizCompletedAt)
    }
}

/// The OpenAPI document types every count as `['integer','string']`, so the
/// server is free to send `12` or `"12"`. Accepting both keeps one stray
/// quoted number from failing an entire screen.
struct FlexibleInt: Decodable {
    let value: Int

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) {
            value = int
        } else if let text = try? container.decode(String.self), let parsed = Int(text) {
            value = parsed
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an integer")
        }
    }
}
