import SwiftUI
import WakaRouteKit

/// 練習 — one question at a time, with a way back to the answer that goes
/// through the student rather than around them.
///
/// The ladder is the whole design: 何を聞かれているか → 小さなヒント →
/// ひとつ手前 → 言いかえ → 似た問題 → （最後に）答え. Every rung is a chance to
/// get there unaided, and only getting there unaided moves the 理解マップ.
struct PracticeSessionView: View {
    @State var viewModel: PracticeViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var reporting: ReportTarget?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                switch viewModel.phase {
                case .starting:
                    LoadingCard()

                case .answering, .retry, .closed:
                    if let item = viewModel.currentItem {
                        QuestionCard(item: item) {
                            reporting = ReportTarget(kind: "question", targetId: nil, title: "この問題を報告")
                        }
                        AnswerArea(viewModel: viewModel)
                        VerdictArea(viewModel: viewModel)
                        HintLadder(viewModel: viewModel) { tier in
                            reporting = ReportTarget(
                                kind: "hint", targetId: tier.rawValue, title: "このヒントを報告"
                            )
                        }
                        AnalysisArea(viewModel: viewModel)
                    }

                case let .finished(session):
                    FinishedCard(session: session) { dismiss() }

                case .nothingDue:
                    NothingDueCard { dismiss() }

                case let .failed(message):
                    FailureCard(message: message) { dismiss() }
                }
            }
            .padding()
            .readableWidth()
        }
        .navigationTitle("練習")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !viewModel.progressText.isEmpty {
                    Text(viewModel.progressText)
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task { await viewModel.begin() }
        .sheet(item: $reporting) { target in
            ReportSheet(target: target) { reason, text in
                await viewModel.report(
                    targetKind: target.kind, targetId: target.targetId, reason: reason, text: text
                )
            }
        }
    }
}

// MARK: - The question

private struct QuestionCard: View {
    let item: PracticeItem
    let onReport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if let code = item.conceptCode {
                    Text(code)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                // Required by the start guide §2.8, and it is the only route a
                // student has when the thing in front of them is wrong.
                Button(action: onReport) {
                    Image(systemName: "exclamationmark.bubble")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("この問題を報告する")
            }

            // The stem is lesson prose and may carry LaTeX, so it goes through
            // the same parser and the same renderer as a lesson body — a
            // fraction in a question has to stack exactly as it does in the
            // lesson that taught it.
            LessonBodyView(blocks: LessonContentParser.parse(item.question.stem))

            if item.attemptCount > 0 {
                Text("のこり \(item.attemptsLeft) 回")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Answering

private struct AnswerArea: View {
    @Bindable var viewModel: PracticeViewModel

    private var isClosed: Bool {
        if case .closed = viewModel.phase { return true }
        return false
    }

    var body: some View {
        if let item = viewModel.currentItem, !isClosed {
            VStack(alignment: .leading, spacing: 12) {
                if item.question.kind == .single {
                    ForEach(item.question.options) { option in
                        OptionRow(
                            option: option,
                            isChosen: viewModel.chosenOption == option.key
                        ) {
                            viewModel.chosenOption = option.key
                        }
                    }
                } else {
                    TextField(
                        item.question.kind == .numeric ? "答えの数を入力" : "答えを入力",
                        text: $viewModel.typedAnswer
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                    // Never autocorrected: 「-3」 and a maths expression are not
                    // prose, and the keyboard helpfully rewriting them would be
                    // marked wrong by the server.
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.send)
                    .onSubmit { Task { await viewModel.submit() } }
                }

                Button {
                    Task { await viewModel.submit() }
                } label: {
                    if viewModel.isWorking {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("答える").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.hasAnswer || viewModel.isWorking)
            }
        }
    }
}

private struct OptionRow: View {
    let option: QuestionOption
    let isChosen: Bool
    let onChoose: () -> Void

    var body: some View {
        Button(action: onChoose) {
            HStack(alignment: .top, spacing: 12) {
                // The key is drawn, and also read out — the shape alone would
                // leave a VoiceOver user with an unlabelled circle.
                Text(option.key)
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 30, height: 30)
                    .background(
                        Circle().fill(isChosen ? Color.accentColor : Color.secondary.opacity(0.15))
                    )
                    .foregroundStyle(isChosen ? Color.white : Color.primary)

                Text(option.text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isChosen ? Color.accentColor.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isChosen ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(option.key)、\(option.text)")
        .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - What the server said

private struct VerdictArea: View {
    let viewModel: PracticeViewModel

    var body: some View {
        switch viewModel.phase {
        case let .retry(result):
            RetryCard(result: result)

        case let .closed(correctAnswer, explanation, wasCorrect):
            ClosedCard(
                correctAnswer: correctAnswer,
                explanation: explanation,
                wasCorrect: wasCorrect
            ) {
                viewModel.advance()
            }

        default:
            EmptyView()
        }
    }
}

/// Wrong, with attempts left.
///
/// Says so and stops. No answer, no strong hint, nothing about the student —
/// just the fact and the door back to the question.
private struct RetryCard: View {
    let result: AnswerResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("ちがうようです", systemImage: "arrow.uturn.left")
                .font(.headline)

            Text("のこり \(result.attemptsLeft) 回。ヒントを見てから、もう一度やってみましょう。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct ClosedCard: View {
    let correctAnswer: String?
    let explanation: String?
    let wasCorrect: Bool
    let onNext: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                wasCorrect ? "正解" : "答え",
                systemImage: wasCorrect ? "checkmark.circle.fill" : "lightbulb"
            )
            .font(.headline)
            .foregroundStyle(wasCorrect ? Color.accentColor : Color.primary)

            if let correctAnswer, !correctAnswer.isEmpty {
                LessonBodyView(blocks: LessonContentParser.parse(correctAnswer))
            }

            if let explanation, !explanation.isEmpty {
                LessonBodyView(blocks: LessonContentParser.parse(explanation))
            }

            Button(action: onNext) {
                Text("つぎへ").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - The ladder

private struct HintLadder: View {
    let viewModel: PracticeViewModel
    let onReport: (HintTier) -> Void

    private var isClosed: Bool {
        if case .closed = viewModel.phase { return true }
        return false
    }

    var body: some View {
        if !isClosed {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(viewModel.hints.enumerated()), id: \.offset) { _, hint in
                    HintCard(hint: hint) { onReport(hint.tier) }
                }

                HStack(spacing: 12) {
                    if viewModel.canHint {
                        Button {
                            Task { await viewModel.requestHint() }
                        } label: {
                            Label(
                                viewModel.hints.isEmpty ? "ヒントを見る" : "もうすこしヒント",
                                systemImage: "lightbulb"
                            )
                        }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.isWorking)
                    }

                    // Last, and only once the ladder is gone. Sitting next to
                    // the first hint it would just be a shorter way to not
                    // learn this.
                    if viewModel.canReveal {
                        Button("答えを見る") {
                            Task { await viewModel.reveal() }
                        }
                        .buttonStyle(.plain)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .disabled(viewModel.isWorking)
                    }
                }
            }
        }
    }
}

private struct HintCard: View {
    let hint: PracticeHint
    let onReport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(hint.tier.displayName, systemImage: "lightbulb.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                Spacer()
                Button(action: onReport) {
                    Image(systemName: "exclamationmark.bubble").font(.caption2)
                }
                .foregroundStyle(.tertiary)
                .accessibilityLabel("このヒントを報告する")
            }

            if !hint.text.isEmpty {
                LessonBodyView(blocks: LessonContentParser.parse(hint.text))
            }

            // A different question, worked through. Its answer is its own —
            // showing it is not showing the answer to the one being asked.
            if let similar = hint.similarQuestion {
                SimilarQuestionCard(question: similar)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct SimilarQuestionCard: View {
    let question: SimilarQuestion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("似た問題")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            LessonBodyView(blocks: LessonContentParser.parse(question.stem))

            if let answer = question.correctAnswerText, !answer.isEmpty {
                Text("答え: \(answer)").font(.subheadline.weight(.medium))
            }
            if let explanation = question.explanation, !explanation.isEmpty {
                LessonBodyView(blocks: LessonContentParser.parse(explanation))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Why it went wrong

private struct AnalysisArea: View {
    @Bindable var viewModel: PracticeViewModel

    private var isClosed: Bool {
        if case .closed = viewModel.phase { return true }
        return false
    }

    var body: some View {
        // Only after the question is closed. An explanation of the mistake
        // while they could still fix it would be the answer in disguise.
        if isClosed {
            VStack(alignment: .leading, spacing: 12) {
                if let analysis = viewModel.analysis {
                    AnalysisCard(analysis: analysis)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("どこでつまずいたか、調べてみますか。")
                            .font(.subheadline)

                        TextField("途中の式や考えたこと（任意）", text: $viewModel.workText, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(2...5)

                        Button {
                            Task { await viewModel.analyzeMistake() }
                        } label: {
                            Label("調べる", systemImage: "magnifyingglass")
                        }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.isWorking)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
    }
}

private struct AnalysisCard: View {
    let analysis: AnswerAnalysis

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Below the confidence floor the server is guessing, and the guide
            // says to treat it as 「わからない」. Dressing a guess as a finding
            // would tell a student something about themselves that nothing
            // actually knows.
            if analysis.isConfident {
                Label(analysis.category.displayName, systemImage: "magnifyingglass")
                    .font(.headline)

                if let description = analysis.misconceptionDescription, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let suggestion = analysis.suggestion, !suggestion.isEmpty {
                    Text(suggestion)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Label("はっきりしませんでした", systemImage: "questionmark.circle")
                    .font(.headline)
                Text("原因は決めつけられません。もう一問やってみると見えてくることがあります。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Ends

private struct LoadingCard: View {
    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("問題を用意しています").font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
    }
}

private struct FinishedCard: View {
    let session: PracticeSession
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("おつかれさま").font(.title3.weight(.semibold))

            Text("\(session.answeredCount) 問中 \(session.correctCount) 問正解")
                .font(.headline)
                .monospacedDigit()

            // Observed and estimated are kept apart, as the start guide §3
            // requires: attempts are a fact, the estimate is a model's opinion.
            if !session.targets.isEmpty {
                Divider()
                ForEach(session.targets) { target in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(target.name).font(.subheadline)
                        Text(
                            "\(target.attempts) 問中 \(target.correct) 問正解"
                                + (target.estimate.map { "・推定 \(String(format: "%.2f", $0))" } ?? "")
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }

            Button(action: onClose) {
                Text("とじる").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// Nothing due. In review mode this is the good news, and it is written that
/// way rather than as a failure.
private struct NothingDueCard: View {
    let onClose: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("いまは復習する問題がありません", systemImage: "checkmark.circle")
        } description: {
            Text("期限が来たものから順に出ます。また来てください。")
        } actions: {
            Button("とじる", action: onClose)
        }
    }
}

private struct FailureCard: View {
    let message: String
    let onClose: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("練習を開けませんでした", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("とじる", action: onClose)
        }
    }
}

// MARK: - Reporting

private struct ReportTarget: Identifiable {
    let kind: String
    /// The hint tier, the analysis id — whatever names the thing inside the
    /// question. Nil when the question itself is what is wrong.
    let targetId: String?
    let title: String

    var id: String { "\(kind)-\(targetId ?? "")" }
}

private struct ReportSheet: View {
    let target: ReportTarget
    let onSend: (String, String?) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var reason = "wrong"
    @State private var text = ""

    private static let reasons: [(code: String, label: String)] = [
        ("wrong", "内容がまちがっている"),
        ("confusing", "わかりにくい"),
        ("inappropriate", "ふさわしくない"),
        ("leak", "答えが書かれている"),
        ("other", "そのほか")
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("どうしましたか") {
                    Picker("理由", selection: $reason) {
                        ForEach(Self.reasons, id: \.code) { item in
                            Text(item.label).tag(item.code)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section {
                    TextField("くわしく（任意）", text: $text, axis: .vertical)
                        .lineLimit(3...6)
                } footer: {
                    Text("送ると、内容をつくっている人に届きます。")
                }
            }
            .navigationTitle(target.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("送る") {
                        Task {
                            await onSend(reason, text.isEmpty ? nil : text)
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}
