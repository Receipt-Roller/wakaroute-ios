import SwiftUI
import WakaRouteKit

/// 学ぶ, on a screen with room for columns.
///
/// The phone pushes four times to reach a lesson: 教科 → 領域 → コース →
/// レッスン一覧 → 本文. Two of those go away here. The 領域 stops being a level
/// of navigation and becomes a **heading** in the course list, and the 教科 moves
/// into a sidebar that stays visible.
///
/// **Two columns, not three, and laid out by hand.**
///
/// Three columns were tried first and collapsed: a 13-inch iPad in portrait is
/// 1024pt, and SwiftUI hides both leading columns rather than squeezing them,
/// leaving the student on an empty "choose something" screen — worse than the
/// phone layout it replaced.
///
/// `NavigationSplitView` was tried next and rendered a **second copy of the
/// app's tab bar** inside its detail column, dimmed: nested inside a `TabView`
/// tab it tries to become the window's root split view and fights the one
/// already there. Its automatic collapsing and overlaying were the problem in
/// both attempts, so this places the two columns explicitly — the same shape
/// the lesson and its quiz use, and predictable at every width.
///
/// This costs no extra requests: every course id and title is already in the
/// path structure cached for the 教科 rings.
struct LearnSplitView: View {
    let catalog: ContentCatalog
    let content: ContentClient
    let queue: LearningActionQueue?
    let cards: CardLibrary

    @State private var subject: SubjectId?

    /// Wide enough for the 教科 名 and its progress, narrow enough to leave the
    /// course list the room it needs.
    private static let sidebarWidth: CGFloat = 280

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $subject) {
                ForEach(catalog.subjects) { overview in
                    SubjectSidebarRow(overview: overview)
                        .tag(overview.id)
                }

                Section {
                    NavigationLink {
                        CardsView(viewModel: CardsViewModel(library: cards))
                    } label: {
                        Label("単語カード・漢字カード", systemImage: "rectangle.on.rectangle.angled")
                    }
                }
            }
            .frame(width: Self.sidebarWidth)

            Divider()

            Group {
                if let subject, let overview = catalog.subjects.first(where: { $0.id == subject }) {
                    // Its own stack, so a course and then a lesson push here
                    // while the 教科 list stays put.
                    NavigationStack {
                        CourseColumn(
                            groups: catalog.courseGroups(inSubject: subject),
                            catalog: catalog,
                            content: content,
                            queue: queue
                        )
                        .navigationTitle(overview.subject.name)
                        .navigationBarTitleDisplayMode(.inline)
                    }
                    .id(subject)
                } else {
                    ContentUnavailableView(
                        "教科をえらんでください",
                        systemImage: "book",
                        description: Text("左の一覧から選ぶと、領域ごとの項目が出ます。")
                    )
                }
            }
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            // Landing on an empty pane would make the iPad *more* steps than the
            // phone, where the five 教科 are the first thing on screen. So one is
            // already chosen; the sidebar still shows which.
            if subject == nil {
                subject = catalog.subjects.first { !$0.isPlanned && !$0.isAwaitingContent }?.id
            }
        }
    }
}

private struct SubjectSidebarRow: View {
    let overview: SubjectOverview

    private var isPlanned: Bool { overview.isPlanned || overview.isAwaitingContent }

    var body: some View {
        HStack(spacing: 12) {
            ProgressRing(
                fraction: overview.completedFraction,
                lineWidth: 4,
                tint: isPlanned ? .secondary : .accentColor
            ) {
                Text(overview.subject.name.prefix(1)).font(.caption.weight(.medium))
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 1) {
                Text(overview.subject.name).font(.body)
                Text(isPlanned ? "準備中" : "\(overview.completedCourses)/\(overview.totalCourses) 項目")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

/// One 教科's courses, with the 領域 as section headings rather than a screen
/// of their own.
private struct CourseColumn: View {
    let groups: [(path: LearningPathSummary, courses: [ContentStructure.Course])]
    let catalog: ContentCatalog
    let content: ContentClient
    let queue: LearningActionQueue?

    var body: some View {
        if groups.isEmpty {
            ContentUnavailableView(
                "準備中です",
                systemImage: "hammer",
                description: Text("この教科の学習内容はまだ公開されていません。")
            )
        } else {
            List {
                ForEach(groups, id: \.path.id) { group in
                    Section(group.path.name) {
                        ForEach(group.courses) { course in
                            NavigationLink {
                                CourseLessonsView(
                                    viewModel: CourseLessonsViewModel(
                                        course: CourseSummary(id: course.id, title: course.title),
                                        content: content,
                                        progress: catalog.progress(forCourse: course.id),
                                        queue: queue
                                    )
                                )
                            } label: {
                                CourseColumnRow(
                                    course: course,
                                    progress: catalog.progress(forCourse: course.id)
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct CourseColumnRow: View {
    let course: ContentStructure.Course
    let progress: CourseProgress?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: progress?.isCompleted == true ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(progress?.isCompleted == true ? .green : .secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text(course.title).font(.body)

                if let progress, progress.totalLessons > 0, !progress.isCompleted, progress.completedLessons > 0 {
                    ProgressView(value: Double(progress.completedLessons), total: Double(progress.totalLessons))
                        .tint(.accentColor)
                    Text("\(progress.totalLessons) レッスン中 \(progress.completedLessons) 終わりました")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
