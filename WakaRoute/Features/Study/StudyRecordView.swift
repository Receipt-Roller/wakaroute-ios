import SwiftUI
import WakaRouteKit

/// 記録 — the timer, a month calendar, and what was actually studied.
struct StudyRecordView: View {
    @State var viewModel: StudyRecordViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    TimerCard(viewModel: viewModel)
                    CalendarSection(viewModel: viewModel)
                    ActivitySection(
                        sessions: viewModel.sessions,
                        pendingUploadCount: viewModel.pendingUploadCount,
                        historyDependencies: viewModel.historyDependencies
                    )
                }
                .padding()
                .readableWidth()
            }
            .navigationTitle("記録")
        }
        .task { await viewModel.load() }
        .alert(
            "前回の記録が残っています",
            isPresented: .constant(viewModel.staleSession != nil)
        ) {
            Button("25分として記録") { Task { await viewModel.keepStale(minutes: 25) } }
            Button("記録しない", role: .destructive) { viewModel.discardStale() }
        } message: {
            Text("タイマーが止まらないままアプリが終了したようです。実際に学習した時間として記録しますか。")
        }
    }
}

// MARK: - Timer

private struct TimerCard: View {
    @Bindable var viewModel: StudyRecordViewModel

    var body: some View {
        VStack(spacing: 16) {
            if let running = viewModel.running {
                Text(elapsed(of: running))
                    .font(.system(size: 52, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .accessibilityLabel("学習中、\(spokenElapsed(of: running))")

                VStack(spacing: 2) {
                    Text(running.title).font(.headline)
                    Text("\(running.subjectName)・\(running.kind.label)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Button("やめる", role: .destructive) {
                        Task { await viewModel.cancel() }
                    }
                    .buttonStyle(.bordered)

                    Button {
                        Task { await viewModel.stop() }
                    } label: {
                        Label("終了して記録", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Image(systemName: "timer")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)

                Text("学習をはじめると時間を記録します")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button {
                    Task {
                        await viewModel.start(title: "自習", subjectName: "数学", kind: .practice)
                    }
                } label: {
                    Label("学習をはじめる", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

            if viewModel.streak.days > 0 {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "flame.fill").foregroundStyle(.orange)
                    Text("\(viewModel.streak.days) 日つづけています")
                        .font(.subheadline)
                        .monospacedDigit()
                    Spacer()
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18))
    }

    /// Derived from the start time against the current tick, so the display is
    /// correct even after the app has been backgrounded for twenty minutes.
    private func elapsed(of session: StudySession) -> String {
        let total = Int(session.duration(asOf: viewModel.tick))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    private func spokenElapsed(of session: StudySession) -> String {
        let minutes = Int(session.duration(asOf: viewModel.tick)) / 60
        return minutes < 1 ? "1分未満" : "\(minutes)分"
    }
}

// MARK: - Calendar

private struct CalendarSection: View {
    @Bindable var viewModel: StudyRecordViewModel

    private var monthTitle: String {
        viewModel.visibleMonth.formatted(.dateTime.year().month(.wide).locale(Locale(identifier: "ja_JP")))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(title: "学習カレンダー", subtitle: monthTitle)
                Spacer()
                Button { viewModel.changeMonth(by: -1) } label: {
                    Image(systemName: "chevron.left")
                }
                .accessibilityLabel("前の月")

                Button { viewModel.changeMonth(by: 1) } label: {
                    Image(systemName: "chevron.right")
                }
                .accessibilityLabel("次の月")
            }

            MonthGrid(totals: viewModel.monthTotals)
                .padding()
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18))
        }
    }
}

private struct MonthGrid: View {
    let totals: [DailyStudyTotal]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)
    private let weekdaySymbols = ["日", "月", "火", "水", "木", "金", "土"]

    /// Blank cells so the first of the month lands under the right weekday.
    private var leadingBlanks: Int {
        guard let first = totals.first else { return 0 }
        return Calendar.current.component(.weekday, from: first.date) - 1
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .accessibilityHidden(true)

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(0..<leadingBlanks, id: \.self) { _ in
                    Color.clear.frame(height: 40)
                }
                ForEach(totals) { total in
                    DayCell(total: total)
                }
            }

            IntensityLegend()
        }
    }
}

/// One day. Shade shows intensity, but the minutes are printed underneath —
/// colour alone must never carry the information (開発ガイド §8).
private struct DayCell: View {
    let total: DailyStudyTotal

    private var dayNumber: Int {
        Calendar.current.component(.day, from: total.date)
    }

    private var intensity: Double {
        guard total.minutes > 0 else { return 0 }
        // Saturates at an hour; beyond that the shade stops changing rather
        // than implying more is always better.
        return min(1.0, 0.25 + Double(total.minutes) / 60.0 * 0.75)
    }

    var body: some View {
        VStack(spacing: 1) {
            Text("\(dayNumber)")
                .font(.caption2.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(intensity > 0.6 ? Color.white : Color.primary)

            Text(total.minutes > 0 ? "\(total.minutes)" : "–")
                .font(.system(size: 9))
                .monospacedDigit()
                .foregroundStyle(intensity > 0.6 ? Color.white.opacity(0.9) : Color.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.accentColor.opacity(intensity))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(.separator, lineWidth: total.isEmpty ? 0.5 : 0)
        )
        .accessibilityElement()
        .accessibilityLabel(spoken)
    }

    private var spoken: String {
        let date = total.date.formatted(.dateTime.month().day().locale(Locale(identifier: "ja_JP")))
        return total.minutes > 0 ? "\(date)、\(total.minutes)分" : "\(date)、学習なし"
    }
}

private struct IntensityLegend: View {
    var body: some View {
        HStack(spacing: 6) {
            Text("すくない").font(.caption2).foregroundStyle(.secondary)
            ForEach([0.0, 0.35, 0.6, 0.85, 1.0], id: \.self) { level in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.accentColor.opacity(level))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.separator, lineWidth: level == 0 ? 0.5 : 0))
                    .frame(width: 14, height: 14)
            }
            Text("おおい").font(.caption2).foregroundStyle(.secondary)
            Spacer()
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Activity log

private struct ActivitySection: View {
    let sessions: [StudySession]
    let pendingUploadCount: Int
    let historyDependencies: (timer: StudyTimer, content: ContentClient)?

    private var recent: [StudySession] {
        Array(sessions.filter(\.isCountable).prefix(20))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let dependencies = historyDependencies {
                NavigationLink {
                    ActivityHistoryView(
                        viewModel: ActivityHistoryViewModel(
                            timer: dependencies.timer,
                            content: dependencies.content
                        )
                    )
                } label: {
                    HStack {
                        SectionHeader(title: "やったこと", subtitle: "レッスン・クイズもまとめて見る")
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }

            SectionHeader(
                title: "学習時間の記録",
                // Stated plainly, not as a warning. Unsent records are normal
                // after studying offline, and they are not lost.
                subtitle: pendingUploadCount > 0
                    ? "\(pendingUploadCount) 件はまだ送信していません"
                    : "新しい順に表示しています"
            )

            if recent.isEmpty {
                Text("まだ記録がありません。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, session in
                        ActivityRow(session: session)
                        if index < recent.count - 1 { Divider() }
                    }
                }
                .padding(.horizontal)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }
}

private struct ActivityRow: View {
    let session: StudySession

    private var minutes: Int { Int(session.duration(asOf: Date())) / 60 }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: session.kind.symbolName)
                .foregroundStyle(.tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).font(.subheadline)
                Text(
                    session.startedAt.formatted(
                        .dateTime.month().day().hour().minute().locale(Locale(identifier: "ja_JP"))
                    ) + "・\(session.subjectName)・\(session.kind.label)"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text(minutes < 1 ? "1分未満" : "\(minutes)分")
                .font(.subheadline.weight(.medium))
                .monospacedDigit()

            if !session.isSynced {
                // Honest about local-only state until the sync API exists.
                Image(systemName: "icloud.slash")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("未同期")
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

/// How a session's kind is written and drawn. Lives here because the study
/// record is the only screen that lets a student choose one.
extension RouteStep.Kind {
    var label: String {
        switch self {
        case .learn: "学ぶ"
        case .practice: "練習"
        case .review: "復習"
        case .check: "確認"
        }
    }

    var symbolName: String {
        switch self {
        case .learn: "book"
        case .practice: "pencil.and.outline"
        case .review: "arrow.clockwise"
        case .check: "checklist"
        }
    }
}
