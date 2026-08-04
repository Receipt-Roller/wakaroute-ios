import Foundation
import Observation
import SwiftUI
import WakaRouteKit

@MainActor
@Observable
final class QuizViewModel {
    enum Phase: Equatable {
        case answering
        case submitting
        case graded(QuizResult)
        /// Sent to the queue because grading needs the network. The attempt is
        /// kept, but no score is shown — inventing one would be worse than
        /// admitting we cannot grade offline.
        case queued
        case failed(message: String)
    }

    private(set) var phase: Phase = .answering
    /// questionId → chosen optionId.
    private(set) var chosen: [String: String] = [:]

    let lessonId: String
    let quiz: LessonQuiz
    private let content: ContentClient
    private let queue: LearningActionQueue?

    /// Generated once per attempt and reused on retry.
    ///
    /// A new key on retry would record a second attempt for the same answers,
    /// and attempts gate certificates.
    private var idempotencyKey = UUID().uuidString

    init(lessonId: String, quiz: LessonQuiz, content: ContentClient, queue: LearningActionQueue? = nil) {
        self.lessonId = lessonId
        self.quiz = quiz
        self.content = content
        self.queue = queue
    }

    var answerableQuestions: [QuizQuestion] {
        quiz.questions.filter(\.isAnswerable)
    }

    /// Questions the app cannot present. Counted so the student is told rather
    /// than silently graded on fewer questions than the quiz contains.
    var unsupportedCount: Int {
        quiz.questions.count - answerableQuestions.count
    }

    var isComplete: Bool {
        answerableQuestions.allSatisfy { chosen[$0.id] != nil }
    }

    var answeredCount: Int {
        answerableQuestions.filter { chosen[$0.id] != nil }.count
    }

    func choose(option: QuizOption, for question: QuizQuestion) {
        guard phase == .answering else { return }
        chosen[question.id] = option.id
    }

    func submit() async {
        guard isComplete else { return }
        phase = .submitting

        let answers = answerableQuestions.compactMap { question -> QuizAnswer? in
            guard let optionId = chosen[question.id] else { return nil }
            return QuizAnswer(questionId: question.id, optionId: optionId)
        }

        do {
            let result = try await content.submitQuiz(
                lessonId: lessonId,
                answers: answers,
                idempotencyKey: idempotencyKey
            )
            phase = .graded(result)
        } catch {
            // Keep the answers with the key they were first sent under, so the
            // replay is the same attempt rather than a second one.
            if let queue {
                await queue.enqueue(
                    PendingAction(
                        kind: .quizSubmit,
                        lessonId: lessonId,
                        answers: answers,
                        idempotencyKey: idempotencyKey
                    )
                )
                phase = .queued
            } else {
                phase = .failed(message: "回答を送信できませんでした。通信状況を確認してください。")
            }
        }
    }

    /// A fresh attempt — new answers, so a new key.
    func retake() {
        chosen = [:]
        idempotencyKey = UUID().uuidString
        phase = .answering
    }

    /// Re-sends the same answers after a failure, keeping the key so the server
    /// treats it as the same attempt.
    func retrySubmit() async {
        await submit()
    }
}

/// Works in two places without knowing which: a sheet on a phone, and a column
/// beside the lesson when the window is wide enough. So it carries its own
/// header rather than relying on navigation chrome — a `.toolbar` in the column
/// case would put the close button in the *lesson's* navigation bar.
struct QuizView: View {
    @State var viewModel: QuizViewModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header

            Form {
                if case let .graded(result) = viewModel.phase {
                    resultSection(result)
                }

                if let instructions = viewModel.quiz.instructions, !instructions.isEmpty {
                    Section { Text(instructions).font(.subheadline) }
                }

                ForEach(Array(viewModel.answerableQuestions.enumerated()), id: \.element.id) { index, question in
                    questionSection(index: index, question: question)
                }

                if viewModel.unsupportedCount > 0 {
                    Section {
                        Label(
                            "\(viewModel.unsupportedCount) 問はこのバージョンでは表示できません。",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    }
                }

                submitSection
            }
            .readableWidth()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(viewModel.quiz.title ?? "確認クイズ")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Button("閉じる", action: onClose)
                .font(.subheadline)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func questionSection(index: Int, question: QuizQuestion) -> some View {
        Section {
            ForEach(question.options) { option in
                Button {
                    viewModel.choose(option: option, for: question)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: viewModel.chosen[question.id] == option.id
                              ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(viewModel.chosen[question.id] == option.id ? Color.accentColor : .secondary)
                        Text(option.text)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(viewModel.chosen[question.id] == option.id ? [.isSelected] : [])
            }
        } header: {
            Text("問\(index + 1)　\(question.questionText)")
                .textCase(nil)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
    }

    @ViewBuilder
    private var submitSection: some View {
        Section {
            switch viewModel.phase {
            case .answering:
                Button {
                    Task { await viewModel.submit() }
                } label: {
                    Text("答え合わせをする").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.isComplete)

            case .submitting:
                HStack { Spacer(); ProgressView(); Text("採点中").foregroundStyle(.secondary); Spacer() }

            case .graded:
                Button {
                    viewModel.retake()
                } label: {
                    Text("もう一度挑戦する").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

            case .queued:
                VStack(spacing: 8) {
                    Label("回答をあずかりました", systemImage: "tray.and.arrow.up")
                        .foregroundStyle(.secondary)
                    Text("いま採点できないので、通信できたときに送ります。結果は「記録」で見られます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)

            case let .failed(message):
                VStack(spacing: 10) {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    Button("再送信") { Task { await viewModel.retrySubmit() } }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity)
            }
        } footer: {
            if case .answering = viewModel.phase {
                Text("\(viewModel.answeredCount) / \(viewModel.answerableQuestions.count) 問に回答しました。")
            }
        }
    }

    /// The score, framed as information rather than a verdict.
    ///
    /// No celebration and no admonishment — a 受験生 who missed the mark needs
    /// to know what to do next, not how to feel about it.
    private func resultSection(_ result: QuizResult) -> some View {
        Section {
            VStack(spacing: 10) {
                Text("\(result.scorePercent)%")
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(result.isPassed ? Color.green : Color.primary)

                Label(
                    result.isPassed ? "合格ラインに届きました" : "合格ラインは \(result.passingScorePercent)% です",
                    systemImage: result.isPassed ? "checkmark.circle.fill" : "arrow.counterclockwise"
                )
                .font(.subheadline)
                .foregroundStyle(result.isPassed ? .green : .secondary)

                if !result.isPassed {
                    Text("もう一度レッスンを読んでから挑戦すると、どこでつまずいたかが見つけやすくなります。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "得点\(result.scorePercent)パーセント。"
                + (result.isPassed ? "合格ラインに届きました。" : "合格ラインは\(result.passingScorePercent)パーセントです。")
            )
        }
    }
}
