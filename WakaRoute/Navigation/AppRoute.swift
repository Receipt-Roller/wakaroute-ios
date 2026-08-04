import SwiftUI
import WakaRouteKit

/// Every destination reachable by pushing.
///
/// One enum rather than per-screen links because the same destinations are
/// reached from more than one tab — tapping 数学 on the home dashboard and
/// tapping it in 理解マップ must land on the identical screen.
enum AppRoute: Hashable {
    case goalDetail
    case editTargetSchools
    case subject(SubjectId)
    case domain(SubjectId, domainId: String)
    case element(SubjectId, ElementId)
    /// The real 領域 list for a 教科 — the same screen the 学ぶ tab pushes.
    case subjectPaths(SubjectId)
    case course(id: String, title: String)
    case lesson(id: String, title: String)
    /// 理解マップ's per-要素 study button. No content is mapped to 要素 yet, so
    /// this is honest about being 計画中 rather than pretending to open a lesson.
    case study(title: String)
}

/// Data every destination needs. Passed down rather than fetched again per
/// screen, so a pushed view cannot disagree with the one that pushed it.
struct MapContext {
    var targetSchools: TargetSchoolList?
    /// Needed by the 志望校 editor, which both reads and writes.
    var goalsRepository: (any TargetSchoolsRepository)?
    var schoolsClient: SchoolsClient?
    var readiness: ExamReadiness
    var subjects: [Subject]
    var mastery: [SubjectId: MasteryRecord]

    /// The real learning hierarchy, so home can push into the same 領域 and
    /// レッスン screens the 学ぶ tab uses rather than a second copy of them.
    var catalog: ContentCatalog?
    var content: ContentClient?
    var queue: LearningActionQueue?

    func subject(_ id: SubjectId) -> Subject? {
        subjects.first { $0.id == id }
    }

    func overview(_ id: SubjectId) -> SubjectOverview? {
        catalog?.subjects.first { $0.id == id }
    }

    func mastery(for id: SubjectId) -> MasteryRecord {
        mastery[id] ?? MasteryRecord()
    }

    func focus(for id: SubjectId) -> StudyFocus? {
        guard let subject = subject(id) else { return nil }
        return StudyFocus(subject: subject, mastery: mastery(for: id))
    }

    /// Which subject an element belongs to. The home screen merges
    /// recommendations from all five, so a recommendation alone does not say
    /// where to navigate.
    func subjectId(containing elementId: ElementId) -> SubjectId? {
        subjects.first { $0.elements.contains { $0.id == elementId } }?.id
    }
}

extension View {
    /// Attached once per NavigationStack so both tabs resolve routes the same.
    func appDestinations(context: MapContext) -> some View {
        navigationDestination(for: AppRoute.self) { route in
            AppRouteView(route: route, context: context)
        }
    }
}

private struct AppRouteView: View {
    let route: AppRoute
    let context: MapContext

    var body: some View {
        switch route {
        case .goalDetail:
            if let schools = context.targetSchools {
                GoalDetailView(schools: schools, readiness: context.readiness)
            }

        case .editTargetSchools:
            if let repository = context.goalsRepository, let client = context.schoolsClient {
                TargetSchoolsView(
                    viewModel: TargetSchoolsViewModel(repository: repository, schools: client),
                    schoolsClient: client
                )
            }

        case let .subject(id):
            if let subject = context.subject(id) {
                SubjectDomainsView(subject: subject, mastery: context.mastery(for: id))
            }

        case let .domain(subjectId, domainId):
            if let subject = context.subject(subjectId),
               let domain = subject.domain(id: domainId) {
                DomainElementsView(
                    subject: subject,
                    domain: domain,
                    mastery: context.mastery(for: subjectId)
                )
            }

        case let .element(subjectId, elementId):
            if let subject = context.subject(subjectId),
               let element = subject.elements.first(where: { $0.id == elementId }) {
                ElementDetailView(
                    subject: subject,
                    element: element,
                    mastery: context.mastery(for: subjectId)
                )
            }

        case let .subjectPaths(id):
            if let overview = context.overview(id), let content = context.content, let catalog = context.catalog {
                SubjectPathsView(overview: overview, content: content, catalog: catalog, queue: context.queue)
            }

        case let .course(id, title):
            if let content = context.content {
                CourseLessonsView(
                    viewModel: CourseLessonsViewModel(
                        course: CourseSummary(id: id, title: title),
                        content: content,
                        progress: context.catalog?.progress(forCourse: id),
                        queue: context.queue
                    )
                )
            }

        case let .lesson(id, title):
            if let content = context.content {
                LessonView(
                    viewModel: LessonViewModel(
                        lesson: .placeholder(id: id, title: title),
                        content: content,
                        queue: context.queue
                    )
                )
            }

        case let .study(title):
            StudyPlaceholderView(title: title)
        }
    }
}

/// Where every 学ぶ / はじめる button lands today.
///
/// Deliberately not a mock lesson. 問題・クイズ・テスト are listed as 未実装 in
/// the サービス仕様, and showing invented content to a student preparing for
/// 受験 would be worse than showing nothing.
struct StudyPlaceholderView: View {
    let title: String

    var body: some View {
        ContentUnavailableView {
            Label("学習コンテンツは準備中です", systemImage: "book.closed")
        } description: {
            Text("「\(title)」の問題・クイズ・テストは、MANABU2 との連携後に利用できるようになります。")
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
