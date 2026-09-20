import SwiftUI
import WakaRouteKit

/// 教科 → パス（領域）→ コース（要素）→ レッスン.
///
/// The five 教科 are always listed, whether or not they have content — a
/// subject that is still being built says so rather than vanishing.
struct LearnView: View {
    @State var viewModel: LearnViewModel
    /// Cards are 教材, so they live with the rest of the material rather than
    /// taking a sixth tab.
    let cards: CardLibrary

    var body: some View {
        GeometryReader { geometry in
            // Columns need somewhere to put them. Below this the sidebar and
            // the course list would each be too narrow to read, so the phone's
            // push-by-push hierarchy is the better answer — including in Split
            // View on an iPad, which is why this asks the window and not the
            // device.
            if geometry.size.width >= StudyLayout.sideBySide,
               case let .ready(catalog) = viewModel.state {
                LearnSplitView(catalog: catalog, content: viewModel.content, queue: viewModel.queue, cards: cards)
            } else {
                stack
            }
        }
        .task { await viewModel.load() }
    }

    private var stack: some View {
        NavigationStack {
            Group {
                switch viewModel.state {
                case .loading:
                    ProgressView("読み込み中").frame(maxWidth: .infinity, maxHeight: .infinity)

                case let .failed(message, canRetry):
                    ContentUnavailableView {
                        Label("読み込めませんでした", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(message)
                    } actions: {
                        if canRetry {
                            Button("再試行") { Task { await viewModel.load() } }
                                .buttonStyle(.borderedProminent)
                        }
                    }

                case let .ready(catalog):
                    List {
                        Section {
                            ForEach(catalog.subjects) { overview in
                                SubjectRow(overview: overview, content: viewModel.content, catalog: catalog, queue: viewModel.queue)
                            }
                        } footer: {
                            Text("教科をひらくと、領域ごとの学習内容が見られます。")
                        }

                        cardsSection

                        if !catalog.unclassified.isEmpty {
                            unclassifiedSection(catalog.unclassified)
                        }
                    }
                }
            }
            .readableWidth()
            .navigationTitle("学ぶ")
            .refreshable { await viewModel.load() }
        }
    }

    private var cardsSection: some View {
        Section {
            NavigationLink {
                CardsView(viewModel: CardsViewModel(library: cards))
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("単語カード・漢字カード").font(.body.weight(.medium))
                        Text("電波がなくても使えます")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "rectangle.on.rectangle.angled").foregroundStyle(.tint)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// Content authored but not labelled with a 教科. Shown so a labelling
    /// mistake is visible rather than silently unreachable.
    private func unclassifiedSection(_ paths: [LearningPathSummary]) -> some View {
        Section {
            ForEach(paths) { path in
                VStack(alignment: .leading, spacing: 2) {
                    Text(path.name).font(.subheadline)
                    Text("教科が設定されていません").font(.caption2).foregroundStyle(.orange)
                }
            }
        } header: {
            Text("未分類")
        } footer: {
            Text("教科ラベルが未設定のため、どの教科にも表示されていません。")
        }
    }
}

private struct SubjectRow: View {
    let overview: SubjectOverview
    let content: ContentClient
    let catalog: ContentCatalog
    let queue: LearningActionQueue?

    var body: some View {
        if overview.isPlanned || overview.isAwaitingContent {
            row.foregroundStyle(.secondary)
        } else {
            NavigationLink {
                SubjectPathsView(overview: overview, content: content, catalog: catalog, queue: queue)
            } label: {
                row
            }
        }
    }

    private var row: some View {
        HStack(spacing: 14) {
            ProgressRing(
                fraction: overview.completedFraction,
                lineWidth: 5,
                tint: overview.isPlanned || overview.isAwaitingContent ? .secondary : .accentColor
            ) {
                Text(overview.subject.name.prefix(1))
                    .font(.subheadline.weight(.medium))
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text(overview.subject.name).font(.headline)
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(overview.subject.name)、\(detailText)")
    }

    private var detailText: String {
        if overview.isPlanned { return "準備中" }
        if overview.isAwaitingContent { return "\(overview.paths.count) 領域・コース準備中" }
        return "\(overview.paths.count) 領域・\(overview.totalCourses) 項目"
    }
}

// MARK: - 領域

struct SubjectPathsView: View {
    let overview: SubjectOverview
    let content: ContentClient
    let catalog: ContentCatalog
    let queue: LearningActionQueue?

    var body: some View {
        List {
            Section {
                ForEach(overview.paths) { path in
                    if path.courseCount == 0 {
                        PathRow(path: path).foregroundStyle(.secondary)
                    } else {
                        NavigationLink {
                            PathCoursesView(
                                viewModel: PathCoursesViewModel(
                                    path: path,
                                    content: content,
                                    progress: catalog.progressByCourse,
                                    queue: queue
                                )
                            )
                        } label: {
                            PathRow(path: path)
                        }
                    }
                }
            } header: {
                Text("領域")
            }
        }
        .readableWidth()
        .navigationTitle(overview.subject.name)
        .navigationBarTitleDisplayMode(.large)
    }
}

private struct PathRow: View {
    let path: LearningPathSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(path.name).font(.body)
            Text(path.courseCount == 0 ? "準備中" : "\(path.courseCount) 項目")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - コース

private struct PathCoursesView: View {
    @State var viewModel: PathCoursesViewModel

    var body: some View {
        List {
            switch viewModel.state {
            case .loading:
                HStack { Spacer(); ProgressView(); Spacer() }

            case let .failed(message):
                Label(message, systemImage: "wifi.exclamationmark").foregroundStyle(.secondary)

            case let .ready(detail):
                Section {
                    ForEach(detail.courses) { course in
                        NavigationLink {
                            CourseLessonsView(
                                viewModel: CourseLessonsViewModel(
                                    course: course,
                                    content: viewModel.contentClient,
                                    progress: viewModel.progressByCourse[course.id],
                                    queue: viewModel.queue
                                )
                            )
                        } label: {
                            CourseRow(course: course, progress: viewModel.progressByCourse[course.id])
                        }
                    }
                } footer: {
                    Text("上から順に学ぶように並んでいます。")
                }
            }
        }
        .readableWidth()
        .navigationTitle(viewModel.path.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
    }
}

private struct CourseRow: View {
    let course: CourseSummary
    let progress: CourseProgress?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: progress?.isCompleted == true ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(progress?.isCompleted == true ? .green : .secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text(course.title).font(.body)

                HStack(spacing: 6) {
                    if course.lessonCount > 0 {
                        Text("\(course.lessonCount) レッスン").font(.caption).foregroundStyle(.secondary)
                    }
                    if let minutes = course.estimatedMinutes {
                        Text("約\(minutes)分").font(.caption).foregroundStyle(.secondary)
                    }
                }

                if let progress, progress.totalLessons > 0, !progress.isCompleted, progress.completedLessons > 0 {
                    ProgressView(value: Double(progress.completedLessons), total: Double(progress.totalLessons))
                        .tint(.accentColor)
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - レッスン一覧

struct CourseLessonsView: View {
    @State var viewModel: CourseLessonsViewModel

    var body: some View {
        List {
            switch viewModel.state {
            case .loading:
                HStack { Spacer(); ProgressView(); Spacer() }

            case let .failed(message):
                Label(message, systemImage: "wifi.exclamationmark").foregroundStyle(.secondary)

            case let .ready(detail):
                if detail.sections.isEmpty {
                    ContentUnavailableView(
                        "レッスンは準備中です",
                        systemImage: "book.closed",
                        description: Text("この項目の学習内容はまだ公開されていません。")
                    )
                } else {
                    ForEach(detail.sections.sorted { $0.orderIndex < $1.orderIndex }) { section in
                        Section(section.title) {
                            ForEach(section.lessons.sorted { $0.orderIndex < $1.orderIndex }) { lesson in
                                NavigationLink {
                                    LessonView(
                                        viewModel: LessonViewModel(
                                            lesson: lesson,
                                            content: viewModel.contentClient,
                                            progress: viewModel.progress?.lesson(lesson.id),
                                            queue: viewModel.queue
                                        )
                                    )
                                } label: {
                                    LessonRow(
                                        lesson: lesson,
                                        progress: viewModel.progress?.lesson(lesson.id)
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
        .readableWidth()
        .navigationTitle(viewModel.course.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
    }
}

private struct LessonRow: View {
    let lesson: LessonSummary
    let progress: LessonProgress?

    private var isComplete: Bool { progress?.isCompleted ?? false }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isComplete ? .green : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(lesson.title).font(.body)
                if let summary = lesson.summary, !summary.isEmpty {
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }

                // The score belongs where the student looks for it. It rides
                // along with course progress, so this costs no extra request.
                if let score = progress?.latestQuizScorePercent {
                    Label {
                        Text("前回 \(score)%")
                    } icon: {
                        Image(systemName: progress?.latestQuizPassed == true
                              ? "checkmark.circle.fill" : "arrow.counterclockwise")
                    }
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(progress?.latestQuizPassed == true ? .green : .orange)
                }
            }

            Spacer(minLength: 6)

            HStack(spacing: 5) {
                if lesson.hasVideo { Image(systemName: "play.rectangle") }
                if lesson.hasSlides { Image(systemName: "rectangle.on.rectangle") }
                if lesson.hasQuiz { Image(systemName: "checklist") }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(lesson.title)、\(isComplete ? "完了" : "未完了")"
            + (progress?.latestQuizScorePercent.map { "、前回のクイズ\($0)パーセント" } ?? "")
        )
    }
}
