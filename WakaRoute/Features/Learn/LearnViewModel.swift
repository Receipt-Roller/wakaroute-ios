import Foundation
import Observation
import WakaRouteKit

@MainActor
@Observable
final class LearnViewModel {
    enum State {
        case loading
        case ready(ContentCatalog)
        case failed(message: String, canRetry: Bool)
    }

    private(set) var state: State = .loading

    let content: ContentClient
    let queue: LearningActionQueue?
    /// Which courses sit in which path. Without it the 教科 rows can show how
    /// much content exists but not how much of it is done, so every subject
    /// reads as untouched however much the student has finished.
    private let structureCache: ContentStructureCache?

    init(
        content: ContentClient,
        queue: LearningActionQueue? = nil,
        structureCache: ContentStructureCache? = nil
    ) {
        self.content = content
        self.queue = queue
        self.structureCache = structureCache
    }

    func load() async {
        state = .loading
        do {
            // Progress is optional: a learner with no history yet is normal,
            // and losing the whole hierarchy because of it would not be.
            async let paths = content.paths()
            let progress = (try? await content.myProgress()) ?? []
            let loadedPaths = try await paths
            let structure = await structureCache?.structure(refreshedAgainst: loadedPaths) ?? ContentStructure()

            state = .ready(ContentCatalog(paths: loadedPaths, progress: progress, structure: structure))
            // Anything recorded offline goes out as soon as the app can reach
            // the server again.
            _ = await queue?.run()
        } catch let error as APIError {
            state = .failed(message: Self.message(for: error), canRetry: error.isTransient)
        } catch {
            state = .failed(message: "学習内容を読み込めませんでした。", canRetry: true)
        }
    }

    private static func message(for error: APIError) -> String {
        switch error {
        case .offline: "インターネットに接続されていません。"
        case .timedOut: "通信に時間がかかっています。"
        case let .http(status, _) where status == 401 || status == 403:
            "学習内容を表示する権限がありません。（\(status)）"
        case .http(let status, _) where status >= 500: "サーバーが応答していません。"
        case .http: "学習内容を読み込めませんでした。"
        case .decoding, .unknown: "内容を読み取れませんでした。"
        }
    }
}

/// Courses inside one 領域.
@MainActor
@Observable
final class PathCoursesViewModel {
    enum State {
        case loading
        case ready(LearningPathDetail)
        case failed(message: String)
    }

    private(set) var state: State = .loading
    private(set) var progressByCourse: [String: CourseProgress] = [:]

    let path: LearningPathSummary
    let contentClient: ContentClient
    let queue: LearningActionQueue?

    init(path: LearningPathSummary, content: ContentClient, progress: [String: CourseProgress], queue: LearningActionQueue? = nil) {
        self.path = path
        self.contentClient = content
        self.progressByCourse = progress
        self.queue = queue
    }

    func load() async {
        state = .loading
        do {
            state = .ready(try await contentClient.path(id: path.id))
        } catch {
            state = .failed(message: "コースを読み込めませんでした。")
        }
    }
}

/// Sections and lessons inside one コース.
@MainActor
@Observable
final class CourseLessonsViewModel {
    enum State {
        case loading
        case ready(CourseDetail)
        case failed(message: String)
    }

    private(set) var state: State = .loading
    private(set) var progress: CourseProgress?

    let course: CourseSummary
    let contentClient: ContentClient
    let queue: LearningActionQueue?

    init(course: CourseSummary, content: ContentClient, progress: CourseProgress?, queue: LearningActionQueue? = nil) {
        self.course = course
        self.contentClient = content
        self.progress = progress
        self.queue = queue
    }

    func load() async {
        state = .loading
        do {
            let detail = try await contentClient.course(id: course.id)
            state = .ready(detail)
            // Per-course progress carries lesson-level completion, which the
            // list needs to tick individual lessons.
            progress = try? await contentClient.courseProgress(id: course.id)
        } catch {
            state = .failed(message: "レッスンを読み込めませんでした。")
        }
    }
}

/// One lesson.
@MainActor
@Observable
final class LessonViewModel {
    enum State {
        case loading
        case ready(LessonDetail)
        case failed(message: String)
    }

    enum CompletionState: Equatable {
        case notComplete
        case completing
        case complete
        /// Recorded on this device, waiting to reach the server.
        case queued
        case failed(message: String)
    }

    private(set) var state: State = .loading
    private(set) var completion: CompletionState = .notComplete

    let lesson: LessonSummary
    let contentClient: ContentClient
    /// What the server already knows about this lesson for this learner.
    let progress: LessonProgress?
    let queue: LearningActionQueue?

    init(
        lesson: LessonSummary,
        content: ContentClient,
        progress: LessonProgress? = nil,
        queue: LearningActionQueue? = nil
    ) {
        self.lesson = lesson
        self.contentClient = content
        self.progress = progress
        self.queue = queue
        self.completion = progress?.isCompleted == true ? .complete : .notComplete
    }

    func load() async {
        state = .loading
        do {
            state = .ready(try await contentClient.lesson(id: lesson.id))

            // Recording a view is best-effort and must never block reading. If
            // it fails it is queued rather than dropped — a student reading on
            // a train still read it.
            do {
                try await contentClient.recordView(lessonId: lesson.id)
            } catch {
                await queue?.enqueue(PendingAction(kind: .view, lessonId: lesson.id))
            }
        } catch {
            state = .failed(message: "レッスンを読み込めませんでした。")
        }
    }

    /// Only ever called from an explicit tap.
    ///
    /// Completion is a claim about the student's learning, so it is never
    /// inferred from scroll position or from leaving the screen.
    func markComplete() async {
        guard completion != .complete else { return }
        completion = .completing
        do {
            try await contentClient.markComplete(lessonId: lesson.id)
            completion = .complete
        } catch {
            // The student did finish it. Queue it and say so, rather than
            // asking them to press the button again when they get home.
            if let queue {
                await queue.enqueue(PendingAction(kind: .complete, lessonId: lesson.id))
                completion = .queued
            } else {
                completion = .failed(message: "完了を記録できませんでした。")
            }
        }
    }
}
