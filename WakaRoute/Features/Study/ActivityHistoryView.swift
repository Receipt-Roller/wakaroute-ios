import Foundation
import Observation
import SwiftUI
import WakaRouteKit

@MainActor
@Observable
final class ActivityHistoryViewModel {
    private(set) var days: [ActivityDay] = []
    private(set) var isLoading = false
    /// Set when the server history could not be fetched. Local study sessions
    /// are still shown, so the screen degrades rather than emptying.
    private(set) var partialFailure = false

    private let timer: StudyTimer
    private let content: ContentClient

    init(timer: StudyTimer, content: ContentClient) {
        self.timer = timer
        self.content = content
    }

    /// Loads the last 90 days.
    ///
    /// Long enough to cover a term of study, short enough that a student with a
    /// year of history does not wait on a huge response.
    func load(days window: Int = 90) async {
        isLoading = true
        defer { isLoading = false }

        let calendar = Calendar.current
        let to = Date()
        let from = calendar.date(byAdding: .day, value: -window, to: to) ?? to
        let fromParameter = ActivityTimeline.dateParameter(from)
        let toParameter = ActivityTimeline.dateParameter(to)

        let sessions = (try? await timer.countableSessions()) ?? []

        async let quizzes = try? content.quizAttempts(from: fromParameter, to: toParameter)
        async let tests = try? content.testAttempts(from: fromParameter, to: toParameter)
        let completions = await lessonCompletions()

        let quizAttempts = await quizzes
        let testAttempts = await tests
        partialFailure = quizAttempts == nil || testAttempts == nil

        days = ActivityTimeline.build(
            sessions: sessions,
            lessonCompletions: completions,
            quizAttempts: quizAttempts ?? [],
            testAttempts: testAttempts ?? []
        )
    }

    /// Lesson completions, gathered per course.
    ///
    /// Only courses the student has actually started are fetched — the overview
    /// lists every course, and asking for detail on all of them would be a
    /// request per course for no benefit.
    private func lessonCompletions() async -> [(courseTitle: String?, lesson: LessonProgress)] {
        guard let overview = try? await content.myProgress() else { return [] }

        var result: [(courseTitle: String?, lesson: LessonProgress)] = []
        for course in overview where course.completedLessons > 0 {
            guard let detail = try? await content.courseProgress(id: course.courseId) else { continue }
            result += detail.completionHistory.map { (course.courseTitle, $0) }
        }
        return result
    }
}

/// やったこと — study time, lessons and quizzes in one sequence.
struct ActivityHistoryView: View {
    @State var viewModel: ActivityHistoryViewModel

    var body: some View {
        Group {
            if viewModel.days.isEmpty && viewModel.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.days.isEmpty {
                ContentUnavailableView(
                    "まだ記録がありません",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("レッスンを学んだり、タイマーを使うとここに残ります。")
                )
            } else {
                List {
                    if viewModel.partialFailure {
                        Section {
                            Label("一部の記録を読み込めませんでした。", systemImage: "wifi.exclamationmark")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    ForEach(viewModel.days) { day in
                        Section {
                            ForEach(day.activities) { activity in
                                ActivityRow(activity: activity)
                            }
                        } header: {
                            DayHeader(day: day)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .readableWidth()
        .navigationTitle("やったこと")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await viewModel.load() }
        .task { await viewModel.load() }
    }
}

private struct DayHeader: View {
    let day: ActivityDay

    var body: some View {
        HStack {
            Text(day.date.formatted(.dateTime.month().day().weekday().locale(Locale(identifier: "ja_JP"))))
            Spacer()
            let minutes = day.totalStudySeconds() / 60
            if minutes > 0 {
                Text("\(minutes) 分").monospacedDigit()
            }
        }
        .textCase(nil)
    }
}

private struct ActivityRow: View {
    let activity: LearningActivity

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(activity.title).font(.subheadline)

                HStack(spacing: 6) {
                    if let time = activity.occurredAt {
                        Text(time.formatted(.dateTime.hour().minute().locale(Locale(identifier: "ja_JP"))))
                            .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    }
                    if let subtitle = activity.subtitle {
                        Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                    }
                }

                detail
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenLabel)
    }

    @ViewBuilder
    private var detail: some View {
        switch activity {
        case let .studied(session):
            Text("\(Int(session.duration(asOf: Date())) / 60) 分")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)

        case .lessonCompleted:
            Text("完了").font(.caption).foregroundStyle(.green)

        case let .quiz(attempt):
            ScoreLabel(
                score: attempt.scorePercent,
                passing: attempt.passingScorePercent,
                isPassed: attempt.isPassed,
                note: nil
            )

        case let .test(attempt):
            ScoreLabel(
                score: attempt.scorePercent,
                passing: attempt.passingScorePercent,
                isPassed: attempt.isPassed,
                // Passing slowly is a different state from passing — it is the
                // gap between 初見で使える and 時間内に安定する.
                note: attempt.passedButOverTime ? "時間超過" : nil
            )
        }
    }

    private var symbol: String {
        switch activity {
        case .studied: "clock"
        case .lessonCompleted: "checkmark.circle.fill"
        case .quiz: "checklist"
        case .test: "doc.text.magnifyingglass"
        }
    }

    private var tint: Color {
        switch activity {
        case .studied: .secondary
        case .lessonCompleted: .green
        case let .quiz(attempt): attempt.isPassed ? .green : .orange
        case let .test(attempt): attempt.isPassed ? .green : .orange
        }
    }

    private var spokenLabel: String {
        switch activity {
        case let .studied(session):
            "\(session.title)、\(Int(session.duration(asOf: Date())) / 60)分"
        case let .lessonCompleted(_, lesson):
            "\(lesson.title ?? "レッスン")、完了"
        case let .quiz(attempt):
            "\(attempt.lessonTitle ?? "クイズ")、\(attempt.scorePercent)パーセント、"
            + (attempt.isPassed ? "合格" : "不合格")
        case let .test(attempt):
            "\(attempt.testTitle ?? "テスト")、\(attempt.scorePercent)パーセント、"
            + (attempt.isPassed ? "合格" : "不合格")
            + (attempt.passedButOverTime ? "、時間超過" : "")
        }
    }
}

/// A score with its pass mark, so the number means something on its own.
private struct ScoreLabel: View {
    let score: Int
    let passing: Int
    let isPassed: Bool
    let note: String?

    var body: some View {
        HStack(spacing: 6) {
            Text("\(score)%")
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(isPassed ? .green : .primary)

            Text("合格ライン \(passing)%")
                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)

            if let note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }
}
