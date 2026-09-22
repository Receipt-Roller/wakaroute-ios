import SwiftUI
import WakaRouteKit

/// 受験日記 — one day: what was done, how it went, and what tomorrow holds.
///
/// Built from a single `GET /{date}`. Everything on it is the server's; nothing
/// here fills in a day the server did not send.
struct JournalDayView: View {
    @State var viewModel: JournalViewModel

    @State private var isEditingDiary = false
    @State private var isAddingEntry = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                DayPicker(viewModel: viewModel)
                WeekStrip(days: viewModel.week, selected: viewModel.date) { day in
                    Task { await viewModel.show(day) }
                }

                if viewModel.loadFailed {
                    LoadFailedNotice { Task { await viewModel.load() } }
                }

                // Always offered, connection or not.
                //
                // A failed read is not a reason to take away the writing. The
                // student on a train is the one who most needs to write the day
                // down, and the outbox is there precisely to hold it until the
                // signal comes back — a screen that answers them with nothing
                // but 「読み込めませんでした」 has thrown that away.
                DiarySection(viewModel: viewModel) { isEditingDiary = true }
                TimeLogSection(viewModel: viewModel) { isAddingEntry = true }

                // The totals are the one thing worth withholding: with no
                // reply from the server, 0分 would be a guess, not a fact.
                if viewModel.record.hasContent {
                    StudyTotalsSection(viewModel: viewModel)
                }

                if viewModel.record.unsentCount > 0 {
                    UnsentNotice(count: viewModel.record.unsentCount)
                }
            }
            .padding()
            .readableWidth()
        }
        .navigationTitle("受験日記")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
        .sheet(isPresented: $isEditingDiary) {
            DiaryEditorView(
                date: viewModel.date,
                draft: DiaryDraft(viewModel.record.diary)
            ) { draft in
                await viewModel.saveDiary(draft)
            }
        }
        .sheet(isPresented: $isAddingEntry) {
            AddLogEntryView(remainingMinutes: viewModel.record.remainingMinutes) { entry in
                await viewModel.addEntry(entry)
            }
        }
        .alert(
            refusalTitle,
            isPresented: Binding(
                get: { viewModel.lastRefusal != nil },
                set: { if !$0 { viewModel.lastRefusal = nil } }
            )
        ) {
            Button("OK", role: .cancel) { viewModel.lastRefusal = nil }
        } message: {
            Text(refusalMessage)
        }
    }

    private var refusalTitle: String {
        switch viewModel.lastRefusal {
        case .dayFull: "1日は24時間までです"
        case .tooManyEntries: "この日の記録がいっぱいです"
        case .dateNotWritable: "この日はもう書けません"
        case .invalidRequest, .learnerTokenRequired, .none: "保存できませんでした"
        }
    }

    /// Plain, and about the rule rather than the student. Nothing here is
    /// phrased as a judgement of how they spent the day.
    private var refusalMessage: String {
        switch viewModel.lastRefusal {
        case .dayFull:
            "記録した時間の合計が24時間を超えています。どれかを短くするか、削除してください。"
        case .tooManyEntries:
            "1日に記録できるのは50件までです。"
        case .dateNotWritable:
            "書けるのは今日から31日前までです。"
        case .invalidRequest:
            "入力の形式が正しくないようです。文字数や時間を確認してください。"
        case .learnerTokenRequired, .none:
            "もう一度ためしてください。"
        }
    }
}

// MARK: - Day selection

private struct DayPicker: View {
    let viewModel: JournalViewModel

    var body: some View {
        HStack {
            Button { Task { await viewModel.goBackOneDay() } } label: {
                Image(systemName: "chevron.left")
            }
            .accessibilityLabel("前の日")

            Spacer()

            VStack(spacing: 2) {
                Text(viewModel.title)
                    .font(.title3.weight(.semibold))
                if viewModel.isToday {
                    Text("きょう").font(.caption).foregroundStyle(.secondary)
                } else if !viewModel.isWritable {
                    Text("記録できる期間をすぎています")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button { Task { await viewModel.goForwardOneDay() } } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!viewModel.canGoForward)
            .accessibilityLabel("次の日")
        }
    }
}

/// The last seven days as totals only.
///
/// Read from `summary`, which carries no diary text by design — this strip
/// stays safe to have on screen with somebody looking over the student's
/// shoulder.
private struct WeekStrip: View {
    let days: [JournalDaySummary]
    let selected: JournalDate
    let onSelect: (JournalDate) -> Void

    private var busiest: Int {
        max(1, days.map { $0.studySelfMinutes + $0.minutesByCategory.values.reduce(0, +) }.max() ?? 1)
    }

    var body: some View {
        if !days.isEmpty {
            HStack(spacing: 6) {
                ForEach(days) { day in
                    Button { onSelect(day.date) } label: {
                        DayColumn(day: day, busiest: busiest, isSelected: day.date == selected)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

private struct DayColumn: View {
    let day: JournalDaySummary
    let busiest: Int
    let isSelected: Bool

    private static let barHeight = 34.0

    private var minutes: Int { day.minutesByCategory.values.reduce(0, +) }

    private var weekday: String {
        day.date.startOfDay.formatted(.dateTime.weekday(.narrow).locale(Locale(identifier: "ja_JP")))
    }

    /// The number alone. 「15日」 wraps to two lines at accessibility text
    /// sizes, and the 日 says nothing the weekday above has not already said.
    private var dayNumber: String {
        "\(Calendar.current.component(.day, from: day.date.startOfDay))"
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(weekday).font(.caption2).foregroundStyle(.secondary)

            // A bar, with the number beside it — shade and height never carry
            // the information on their own (開発ガイド §8). The slot is a fixed
            // height so every column stands on the same line, and so the strip
            // does not jump when the week's first minutes are logged.
            ZStack(alignment: .bottom) {
                Color.clear
                RoundedRectangle(cornerRadius: 3)
                    .fill(minutes > 0 ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.18))
                    .frame(height: max(4, Self.barHeight * Double(minutes) / Double(busiest)))
            }
            .frame(height: Self.barHeight)

            Text(dayNumber)
                .font(.caption2.weight(isSelected ? .bold : .regular))
                .monospacedDigit()

            Image(systemName: day.hasDiary ? "text.book.closed.fill" : "circle.dotted")
                .font(.system(size: 8))
                .foregroundStyle(day.hasDiary ? Color.accentColor : Color.secondary.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : .clear)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var spoken: String {
        let date = day.date.startOfDay.formatted(
            .dateTime.month().day().locale(Locale(identifier: "ja_JP"))
        )
        let recorded = minutes > 0 ? "記録 \(minutes)分" : "記録なし"
        return "\(date)、\(recorded)、\(day.hasDiary ? "日記あり" : "日記なし")"
    }
}

// MARK: - Diary

private struct DiarySection: View {
    let viewModel: JournalViewModel
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                // 「きょう」 only when it is. Yesterday's page saying きょう is a
                // small lie on a screen whose whole job is which day was which.
                SectionHeader(
                    title: viewModel.isToday ? "きょうのふりかえり" : "この日のふりかえり",
                    subtitle: "できたこと・困ったこと・明日やること"
                )
                Spacer()
                Button(viewModel.record.diary == nil ? "書く" : "編集", action: onEdit)
                    .font(.subheadline)
                    .disabled(!viewModel.isWritable)
            }

            if viewModel.record.isDiaryUnsent {
                UnsentMark(text: "まだ送信していません")
            }

            if let diary = viewModel.record.diary {
                VStack(alignment: .leading, spacing: 14) {
                    DiaryField(label: "できたこと", text: diary.achievements)
                    DiaryField(label: "困ったこと", text: diary.struggles)
                    DiaryField(label: "明日やること", text: diary.tomorrowPlan)

                    if diary.focus != nil || diary.fatigue != nil {
                        Divider()
                        HStack(spacing: 20) {
                            MoodReading(label: "集中", value: diary.focus)
                            MoodReading(label: "つかれ", value: diary.fatigue)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
            } else {
                EmptyDiaryCard(isWritable: viewModel.isWritable, onEdit: onEdit)
            }
        }
    }
}

private struct DiaryField: View {
    let label: String
    let text: String?

    var body: some View {
        if let text, !text.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(text)
                    .font(.body)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

private struct MoodReading: View {
    let label: String
    let value: Int?

    var body: some View {
        if let value {
            HStack(spacing: 6) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                // The number is written out; the dots are decoration on top of
                // it, never instead of it.
                Text("\(value) / 5").font(.subheadline.weight(.medium)).monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(label) 5 段階のうち \(value)")
        }
    }
}

private struct EmptyDiaryCard: View {
    let isWritable: Bool
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isWritable ? "まだ何も書いていません。" : "この日は書かれていません。")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if isWritable {
                // Deliberately about the day, not about effort. Nothing here
                // asks whether they did enough.
                Text("うまくいったこと、つまずいたこと、明日やること。ひとことでかまいません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: onEdit) {
                    Label("書いてみる", systemImage: "square.and.pencil")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Time log

private struct TimeLogSection: View {
    let viewModel: JournalViewModel
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(title: "一日の時間", subtitle: "学校・部活・睡眠もふくめて")
                Spacer()
                Button("追加", action: onAdd)
                    .font(.subheadline)
                    .disabled(!viewModel.isWritable)
            }

            if viewModel.record.rows.isEmpty {
                Text(viewModel.isWritable
                     ? "「追加」から、その日にやったことを分で記録できます。"
                     : "この日の記録はありません。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.record.rows.enumerated()), id: \.element.id) { index, row in
                        LogEntryRow(row: row) {
                            guard let entry = row.entry else { return }
                            Task { await viewModel.deleteEntry(entry) }
                        }
                        if index < viewModel.record.rows.count - 1 { Divider() }
                    }
                }
                .padding(.horizontal)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))

                CategoryBreakdown(rows: viewModel.record.minutesByCategory)
            }

            if !viewModel.record.autoStudy.isEmpty {
                AutoStudyList(sessions: viewModel.record.autoStudy)
            }
        }
    }
}

private struct LogEntryRow: View {
    let row: DayLogRow
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: row.category.symbolName)
                .foregroundStyle(row.category.countsAsStudy ? Color.accentColor : Color.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.category.displayName).font(.subheadline)
                if let detail = row.detailLine {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                if !row.isSent {
                    Text("まだ送信していません")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 8)

            Text(row.durationMinutes.asDuration)
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .accessibilityLabel(row.durationMinutes.asDuration)

            // A visible menu rather than a swipe. These rows are in a VStack,
            // not a List, so `swipeActions` would do nothing at all — and even
            // where it works, a gesture with no mark on screen is not a way to
            // offer a student the only means of fixing a mistyped entry.
            //
            // Offered only once the server has the block: there is no id to
            // delete until then, and saying it is gone while it is still on its
            // way would not be true.
            if row.isSent {
                Menu {
                    Button("削除", systemImage: "trash", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("\(row.category.displayName) の記録を編集")
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }
}

private struct CategoryBreakdown: View {
    let rows: [CategoryMinutes]

    private var total: Int { max(1, rows.map(\.minutes).reduce(0, +)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows) { row in
                HStack(spacing: 10) {
                    Text(row.category.displayName)
                        .font(.caption)
                        .frame(width: 96, alignment: .leading)

                    GeometryReader { geometry in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(row.category.countsAsStudy ? Color.accentColor : Color.secondary.opacity(0.35))
                            .frame(width: geometry.size.width * Double(row.minutes) / Double(total))
                    }
                    .frame(height: 8)

                    Text(row.minutes.asDuration)
                        .font(.caption)
                        .monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(row.category.displayName) \(row.minutes.asDuration)")
            }
        }
        .padding(.top, 4)
    }
}

/// What MANABU2 recorded by itself — the study timer, and sessions the app
/// reported afterwards. Shown so the day reads whole, and marked as not the
/// student's own entry so the two are never mistaken for each other.
private struct AutoStudyList: View {
    let sessions: [AutoStudyEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("アプリが記録した学習")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                    HStack(spacing: 12) {
                        Image(systemName: "timer")
                            .foregroundStyle(.tint)
                            .frame(width: 24)
                        Text(session.subject ?? "学習").font(.subheadline)
                        Spacer(minLength: 8)
                        Text(session.durationMinutes.asDuration)
                            .font(.subheadline.weight(.medium))
                            .monospacedDigit()
                    }
                    .padding(.vertical, 10)
                    .accessibilityElement(children: .combine)

                    if index < sessions.count - 1 { Divider() }
                }
            }
            .padding(.horizontal)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

// MARK: - Totals

/// The day's two study numbers, side by side and never added up.
///
/// A student who runs the timer for 25 minutes and also logs 40 minutes of
/// 自主学習 for the same evening has somewhere between 40 and 65 minutes of
/// study, and nothing on either side knows which. Printing a single total here
/// would be inventing the answer — so both are shown, each labelled with where
/// it came from.
private struct StudyTotalsSection: View {
    let viewModel: JournalViewModel

    /// Which of the two the student's eye should land on. Normally their own
    /// record; the timer's only on a day they logged nothing themselves.
    private var headline: StudySource { viewModel.record.headlineStudy.source }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "学習時間")

            AdaptiveRow(spacing: 12) {
                TotalCard(
                    title: StudySource.learner.displayName,
                    minutes: viewModel.record.studySelfMinutes,
                    caption: "自主学習・宿題・塾",
                    isHeadline: headline == .learner
                )
                TotalCard(
                    title: StudySource.app.displayName,
                    minutes: viewModel.record.studyAutoMinutes,
                    caption: "学習タイマー",
                    isHeadline: headline == .app
                )
            }

            Text("同じ時間を両方で記録していることがあるため、合計はしていません。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let practice = viewModel.record.practice, practice.answered > 0 {
                Text("練習問題 \(practice.answered) 問中 \(practice.correct) 問正解")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct TotalCard: View {
    let title: String
    let minutes: Int
    let caption: String
    /// The one this screen leads with. Both are always shown — this only says
    /// which to read first, and it is never a claim that the other is wrong.
    let isHeadline: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(minutes.asDuration)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(isHeadline ? Color.primary : Color.secondary)
            Text(caption).font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.tint.opacity(isHeadline ? 0.45 : 0), lineWidth: 1.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(minutes.asDuration)、\(caption)")
    }
}

// MARK: - Notices

/// A quiet mark on something the student can see but the server has not
/// acknowledged. Never styled as an error.
private struct UnsentMark: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "icloud.slash").font(.caption2)
            Text(text).font(.caption2)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.tertiary)
        .accessibilityElement(children: .combine)
    }
}

/// Stated plainly, not as a warning. Writing on a train is normal, and nothing
/// written is lost.
private struct UnsentNotice: View {
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "icloud.slash").foregroundStyle(.secondary)
            Text("\(count) 件はまだ送信していません。あとで自動的に送ります。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

/// A line, not a wall.
///
/// It used to be a `ContentUnavailableView` filling the screen, which was the
/// wrong shape: the day's records could not be read, but everything the student
/// might want to *write* still works.
private struct LoadFailedNotice: View {
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash").foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("記録を読み込めませんでした").font(.subheadline)
                Text("いま書いたものは、つながったときに送ります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)
            Button("再読み込み", action: retry).font(.subheadline)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Shared display

extension Int {
    /// 90 → 「1時間30分」. Minutes are what the student entered; hours are only
    /// for reading it back.
    var asDuration: String {
        guard self >= 60 else { return "\(self)分" }
        let hours = self / 60
        let minutes = self % 60
        return minutes == 0 ? "\(hours)時間" : "\(hours)時間\(minutes)分"
    }
}

extension JournalCategory {
    var symbolName: String {
        switch self {
        case .school: "building.columns"
        case .club: "figure.run"
        case .cramSchool: "person.2"
        case .selfStudy: "pencil.and.outline"
        case .homework: "doc.text"
        case .screen: "iphone"
        case .sleep: "moon.zzz"
        case .free: "cup.and.saucer"
        default: "circle"
        }
    }
}
