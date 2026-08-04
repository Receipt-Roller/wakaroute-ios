import SwiftUI
import WakaRouteKit

struct HomeView: View {
    @State var viewModel: HomeViewModel

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.state {
                case .loading:
                    ProgressView("読み込み中")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                case let .failed(message):
                    FailureView(message: message) {
                        Task { await viewModel.load() }
                    }

                case let .ready(content):
                    ReadyHomeView(content: content)
                        .appDestinations(context: content.context)
                }
            }
            .navigationTitle("ホーム")
            .refreshable { await viewModel.load() }
        }
        .task { await viewModel.load() }
    }
}

private struct ReadyHomeView: View {
    let content: HomeContent

    private var digest: HomeDigest { content.digest }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                // The goal stays full width — it is the headline, and the ring
                // and the school name read better across than stacked in half.
                // Below it the two sections sit side by side, which is what
                // stops the lower half of an iPad being empty.
                let twoColumn = geometry.size.width >= StudyLayout.sideBySide

                VStack(alignment: .leading, spacing: 28) {
                    if content.isSample {
                        SampleDataBanner()
                    }

                    goalSection

                    if content.contentUnavailable {
                        ContentUnreachableNotice()
                    } else if twoColumn {
                        HStack(alignment: .top, spacing: 28) {
                            NextStepsSection(digest: digest)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            SubjectProgressSection(digest: digest, context: content.context)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        NextStepsSection(digest: digest)
                        SubjectProgressSection(digest: digest, context: content.context)
                    }
                }
                .padding()
                .readableWidth(twoColumn ? ReadableWidth.wide : ReadableWidth.maximum)
            }
        }
    }

    @ViewBuilder
    private var goalSection: some View {
        if let goal = content.goal {
            NavigationLink(value: AppRoute.goalDetail) {
                GoalCard(
                    goal: goal,
                    digest: digest,
                    otherSchoolCount: content.targetSchools?.alternatives.count ?? 0,
                    daysRemaining: content.targetSchools?.daysRemaining
                )
            }
            .buttonStyle(.plain)
        } else {
            SetGoalPrompt()
        }
    }
}

/// A student with no 志望校 yet gets an invitation, not an empty space.
private struct SetGoalPrompt: View {
    var body: some View {
        NavigationLink(value: AppRoute.editTargetSchools) {
            AdaptiveRow {
                Image(systemName: "flag.checkered")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("めざす高校を決める").font(.headline)
                    Text("目標を決めると、入試までの日数と進みぐあいがわかります。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                RowChevron()
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

/// The goal, stated the way the student holds it: a school and a date.
///
/// The ring is **how much of the material has been finished** — not a 理解度.
/// Reading a lesson is evidence a student read it, and calling that
/// understanding would be a claim the app cannot support. When mastery levels
/// arrive from the 理解マップ this is where they belong.
///
/// No countdown scare tactics: the days remaining are information, not
/// pressure, so they are shown plainly and never in red.
private struct GoalCard: View {
    let goal: TargetSchool
    let digest: HomeDigest
    let otherSchoolCount: Int
    /// Days to the *soonest* exam across all 志望校, computed by the server.
    /// Not derived from the 第一志望's date, which is frequently later.
    let daysRemaining: Int?

    var body: some View {
        VStack(spacing: 16) {
            AdaptiveRow(spacing: 18) {
                ProgressRing(fraction: digest.progressFraction, lineWidth: 11) {
                    VStack(spacing: 0) {
                        Text("\(Int(digest.progressFraction * 100))")
                            .font(.title2.bold())
                            .monospacedDigit()
                        Text("%").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 92, height: 92)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Text("めざす高校")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if otherSchoolCount > 0 {
                            Text("ほか \(otherSchoolCount) 校")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.secondary.opacity(0.15), in: Capsule())
                        }
                    }

                    Text(goal.name)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)

                    if let daysRemaining {
                        Label("入試まで あと \(daysRemaining) 日", systemImage: "calendar")
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    } else {
                        Label("入試日を設定しましょう", systemImage: "calendar.badge.plus")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)

                RowChevron()
            }

            Divider()
            TodayRow(digest: digest)
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "めざす高校、\(goal.name)。"
            + (daysRemaining.map { "入試まであと\($0)日。" } ?? "入試日は未設定。")
            + "学習ずみは\(digest.completedCourses)、全\(digest.totalCourses)項目中。"
        )
    }
}

/// Today at a glance: how long, and how many days running.
///
/// A streak is encouragement, never a penalty. A broken one for a student
/// preparing for 受験 is a bad day, not a failure worth punishing — so a zero
/// is stated plainly and nothing is coloured red.
private struct TodayRow: View {
    let digest: HomeDigest

    var body: some View {
        AdaptiveRow(spacing: 8) {
            Label {
                Text(digest.todayMinutes > 0 ? "今日 \(digest.todayMinutes) 分" : "今日はまだ")
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
            } icon: {
                Image(systemName: "clock").foregroundStyle(.secondary)
            }

            if digest.streak.days > 0 {
                Label {
                    Text("\(digest.streak.days) 日つづけています")
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "flame.fill").foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 「つぎにやること」— the point of the screen.
///
/// Each row says what to do *and why*, in terms the student can check against
/// their own memory. A suggestion they do not believe is one they will skip.
private struct NextStepsSection: View {
    let digest: HomeDigest

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "つぎにやること", subtitle: subtitle)

            if digest.nextSteps.isEmpty {
                EmptyNextSteps(digest: digest)
            } else {
                ForEach(digest.nextSteps) { step in
                    NavigationLink(value: route(for: step)) {
                        NextStepCard(step: step)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// The subtitle follows the top row, because these are different promises:
    /// where to begin, where to go back to, or simply what to pick up again.
    private var subtitle: String? {
        guard let first = digest.nextSteps.first else { return nil }
        if case let .unblock(level, struggling, _) = first.reason {
            if struggling { return "先に進むために、戻っておきたい順に並べています" }
            return level == .notStarted
                ? "ここから始めると、あとが続けて進みます"
                : "ここを終えると、あとが続けて進みます"
        }
        return "もう一度やっておきたいものを先に並べています"
    }

    /// A retry knows its lesson; a resumed course only knows the course, so it
    /// lands on the lesson list and lets the student pick up where they were.
    private func route(for step: NextStep) -> AppRoute {
        if let lessonId = step.lessonId {
            return .lesson(id: lessonId, title: step.title)
        }
        return .course(id: step.courseId ?? "", title: step.title)
    }
}

/// Nothing to suggest means one of three quite different things, and telling
/// them apart is the difference between "well done" and "nothing works".
private struct EmptyNextSteps: View {
    let digest: HomeDigest

    var body: some View {
        Group {
            if !digest.hasContent {
                message("学習内容はまだ公開されていません。", detail: "公開されたら、ここに出てきます。")
            } else if !digest.hasStarted {
                message("まずは1つ、ひらいてみましょう。", detail: "「学ぶ」から教科をえらべます。")
            } else {
                message("もどってやり直すものはありません。", detail: "「学ぶ」から次に進めます。")
            }
        }
    }

    private func message(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}

private struct NextStepCard: View {
    let step: NextStep

    var body: some View {
        AdaptiveRow {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(step.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)

                if let courseTitle = step.courseTitle {
                    Text(courseTitle).font(.caption).foregroundStyle(.secondary)
                }

                Text(reasonText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            RowChevron()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(step.title)、\(accessibleReason)")
    }

    private var symbol: String {
        switch step.reason {
        case let .unblock(level, struggling, _):
            if struggling { "arrow.turn.left.up" } else { level == .notStarted ? "flag" : "play.circle" }
        case .retryQuiz: "arrow.counterclockwise"
        case .resumeCourse: "play.circle"
        }
    }

    /// Orange marks something that went wrong. Neither a starting point nor a
    /// 要素 the student is calmly working through has — only a quiz sat and
    /// missed. The icon and the wording already differ, so nothing depends on
    /// telling the colours apart — 開発ガイド §8.
    private var tint: Color {
        switch step.reason {
        case let .unblock(_, struggling, _): struggling ? .orange : .accentColor
        case .retryQuiz: .orange
        case .resumeCourse: .accentColor
        }
    }

    /// Naming one is concrete; a bare count is not. Both together explain why
    /// this is worth the student's time.
    private var reasonText: String {
        switch step.reason {
        case let .unblock(level, struggling, unblocks):
            // Three situations, and only one is a setback. A student who has
            // not begun has not stumbled, and neither has one partway through
            // reading — the same distinction 領域 make between これから, 学習中
            // and 手前でつまずき.
            if struggling {
                "もう一度ここを固めると、\(named(unblocks))に進めます"
            } else if level == .notStarted {
                "ここから始めると、\(named(unblocks))に進めます"
            } else {
                "ここを終えると、\(named(unblocks))に進めます"
            }
        case let .retryQuiz(score, passing):
            "前回 \(score)%・合格ラインは \(passing)%"
        case let .resumeCourse(completed, total):
            total > 0 ? "\(total) レッスン中 \(completed) 終わりました" : "つづきから"
        }
    }

    private func named(_ unblocks: [String]) -> String {
        guard let first = unblocks.first else { return "この先" }
        return unblocks.count > 1 ? "\(first) ほか \(unblocks.count - 1) 項目" : first
    }

    private var accessibleReason: String {
        switch step.reason {
        case let .unblock(level, struggling, unblocks):
            if struggling {
                "クイズが合格ラインに届いていません。ここを固めると、\(unblocks.joined(separator: "、"))に進めます"
            } else if level == .notStarted {
                "まだ始めていません。ここから始めると、\(unblocks.joined(separator: "、"))に進めます"
            } else {
                "いま\(level.label)。ここを終えると、\(unblocks.joined(separator: "、"))に進めます"
            }
        case let .retryQuiz(score, passing):
            "前回のクイズは\(score)パーセント、合格ラインは\(passing)パーセントです"
        case let .resumeCourse(completed, total):
            total > 0 ? "\(total)レッスン中\(completed)レッスンが終わっています" : "つづきから"
        }
    }
}

/// The five subjects, so a glance tells the student where they stand.
private struct SubjectProgressSection: View {
    let digest: HomeDigest
    let context: MapContext

    private let columns = [GridItem(.adaptive(minimum: 92), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "5教科の進み", subtitle: "教科をひらくと領域ごとに見られます")

            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(digest.subjects) { overview in
                    if let route = route(for: overview) {
                        NavigationLink(value: route) {
                            SubjectCell(overview: overview)
                        }
                        .buttonStyle(.plain)
                    } else {
                        // Nothing behind it yet, and a dead push is worse than
                        // no push.
                        SubjectCell(overview: overview)
                    }
                }
            }

            MapPlannedNote()
        }
    }

    private func route(for overview: SubjectOverview) -> AppRoute? {
        // The 理解マップ wins when there is one to show — today only under
        // -useSampleData, since no API supplies mastery levels.
        if context.subject(overview.id) != nil { return .subject(overview.id) }
        return overview.isPlanned ? nil : .subjectPaths(overview.id)
    }
}

private struct SubjectCell: View {
    let overview: SubjectOverview

    private var isPlanned: Bool { overview.isPlanned || overview.isAwaitingContent }

    var body: some View {
        VStack(spacing: 8) {
            ProgressRing(
                fraction: overview.completedFraction,
                lineWidth: 8,
                tint: isPlanned ? .secondary : .accentColor
            ) {
                if isPlanned {
                    Image(systemName: "hammer").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("\(overview.completedCourses)/\(overview.totalCourses)")
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                }
            }
            .frame(width: 68, height: 68)

            Text(overview.subject.name).font(.subheadline.weight(.medium))
            Text(standing).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            isPlanned
                ? "\(overview.subject.name)、準備中"
                : "\(overview.subject.name)、\(overview.totalCourses)項目中\(overview.completedCourses)項目が終了、\(standing)"
        )
    }

    /// 「これから」 for a subject never opened — never 「つまずき」. Telling a 中3
    /// student they have already failed at something they have not begun is
    /// both untrue and discouraging.
    private var standing: String {
        if isPlanned { return "準備中" }
        if overview.completedCourses == overview.totalCourses { return "ひととおり終了" }
        if overview.startedCourses == 0 { return "これから" }
        return "学習中"
    }
}

/// The 理解マップ is the plan, not a secret. Saying where it will appear is
/// better than leaving a gap the student reads as the app being thin.
private struct MapPlannedNote: View {
    var body: some View {
        Label(
            "領域ごとの得意・苦手がわかる「理解マップ」は準備中です。",
            systemImage: "map"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }
}

/// The learning content could not be fetched. Said plainly, next to the parts
/// that still work, rather than replacing the whole screen.
private struct ContentUnreachableNotice: View {
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("学習内容を読み込めませんでした").font(.subheadline.weight(.medium))
                Text("下に引くと、もう一度読み込みます。").font(.caption)
            }
        } icon: {
            Image(systemName: "wifi.exclamationmark")
        }
        .foregroundStyle(.secondary)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Shared pieces

struct SectionHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title3.weight(.semibold))
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Shown wherever a feature has no API behind it yet. The 開発ガイド requires
/// unbuilt features be stated as 計画中 rather than mocked up as working.
struct PlannedFeatureView: View {
    let reason: String

    var body: some View {
        ContentUnavailableView {
            Label("準備中の機能です", systemImage: "hammer")
        } description: {
            Text(reason)
        }
    }
}

struct FailureView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("読み込めませんでした", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("再試行", action: retry).buttonStyle(.borderedProminent)
        }
    }
}

/// Impossible to miss, so fixture data can never be mistaken for a real record.
struct SampleDataBanner: View {
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("サンプル表示").font(.subheadline.weight(.semibold))
                Text("理解マップはデザイン確認用の仮データです。実際の学習記録ではありません。")
                    .font(.caption)
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundStyle(.orange)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}
