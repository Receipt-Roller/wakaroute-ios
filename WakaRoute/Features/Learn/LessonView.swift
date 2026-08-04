import SwiftUI
import WakaRouteKit

struct LessonView: View {
    @State var viewModel: LessonViewModel

    /// Held here, not built inside the body, so the student's answers survive a
    /// rotation. Rotating an iPad moves the quiz between a column and a sheet;
    /// rebuilding the view model on the way would silently discard everything
    /// they had chosen.
    @State private var quiz: QuizViewModel?

    var body: some View {
        GeometryReader { geometry in
            let sideBySide = geometry.size.width >= StudyLayout.sideBySide

            HStack(spacing: 0) {
                lessonColumn

                // Reading and answering at the same time is the whole reason to
                // use the extra width: on a phone the quiz covers the lesson, so
                // a student who wants to check something has to close it first.
                if sideBySide, let quiz {
                    Divider()
                    QuizView(viewModel: quiz, onClose: { self.quiz = nil })
                        .frame(width: geometry.size.width * 0.42)
                        .transition(.move(edge: .trailing))
                }
            }
            .sheet(isPresented: .init(
                get: { !sideBySide && quiz != nil },
                set: { if !$0 { quiz = nil } }
            )) {
                if let quiz {
                    QuizView(viewModel: quiz, onClose: { self.quiz = nil })
                }
            }
        }
        .navigationTitle(viewModel.lesson.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.load()
            #if DEBUG
            // Design review: the split layout only appears once the quiz is
            // open, which is two taps in. `-withQuiz` gets there directly.
            if ProcessInfo.processInfo.arguments.contains("-withQuiz"),
               case let .ready(lesson) = viewModel.state,
               let lessonQuiz = lesson.quiz, !lessonQuiz.questions.isEmpty {
                quiz = QuizViewModel(
                    lessonId: lesson.id,
                    quiz: lessonQuiz,
                    content: viewModel.contentClient,
                    queue: viewModel.queue
                )
            }
            #endif
        }
    }

    private var lessonColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                switch viewModel.state {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)

                case let .failed(message):
                    ContentUnavailableView("読み込めませんでした", systemImage: "wifi.exclamationmark", description: Text(message))

                case let .ready(lesson):
                    if let summary = lesson.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let html = lesson.bodyHtml, !html.isEmpty {
                        LessonBodyView(blocks: LessonContentParser.parse(html))
                    } else {
                        Text("このレッスンには本文がありません。")
                            .foregroundStyle(.secondary)
                    }

                    if lesson.videoUrl != nil || lesson.slidesEmbedUrl != nil {
                        mediaNotice
                    }

                    if let quiz = lesson.quiz, !quiz.questions.isEmpty {
                        quizControl(quiz: quiz, lessonId: lesson.id)
                    }

                    completionControl
                }
            }
            .padding()
            .readableWidth()
        }
        .frame(maxWidth: .infinity)
    }

    /// 確認クイズ. Opened deliberately rather than shown alongside from the
    /// start — a student looking at the questions before reading will answer
    /// them instead of learning, however much room the screen has.
    private func quizControl(quiz: LessonQuiz, lessonId: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                self.quiz = QuizViewModel(
                    lessonId: lessonId,
                    quiz: quiz,
                    content: viewModel.contentClient,
                    queue: viewModel.queue
                )
            } label: {
                Label("確認クイズにすすむ（\(quiz.questions.count)問）", systemImage: "checklist")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            if let score = viewModel.progress?.latestQuizScorePercent {
                Label {
                    Text(viewModel.progress?.latestQuizPassed == true
                         ? "前回は \(score)% で合格しました。合格ラインは \(quiz.passingScorePercent)% です。"
                         : "前回は \(score)% でした。合格ラインは \(quiz.passingScorePercent)% です。")
                } icon: {
                    Image(systemName: viewModel.progress?.latestQuizPassed == true
                          ? "checkmark.circle.fill" : "arrow.counterclockwise")
                }
                .font(.caption)
                .foregroundStyle(viewModel.progress?.latestQuizPassed == true ? .green : .secondary)
            } else {
                Text("合格ラインは \(quiz.passingScorePercent)% です。何度でも挑戦できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Video and slides are not rendered yet. Saying so is better than an
    /// empty space the student assumes is broken.
    private var mediaNotice: some View {
        Label("動画・スライドはこのバージョンでは表示できません。", systemImage: "play.slash")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    /// Shown only once the lesson is finished — asking someone what they made
    /// of a lesson they have not read yet would collect noise.
    private var feedbackControl: some View {
        LessonFeedbackView(
            viewModel: LessonFeedbackViewModel(
                lessonId: viewModel.lesson.id,
                content: viewModel.contentClient,
                queue: viewModel.queue
            )
        )
    }

    @ViewBuilder
    private var completionControl: some View {
        switch viewModel.completion {
        case .notComplete:
            Button {
                Task { await viewModel.markComplete() }
            } label: {
                Label("学習を完了にする", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

        case .completing:
            HStack { ProgressView(); Text("記録中").foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity)

        case .complete:
            VStack(spacing: 16) {
                Label("完了しました", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity)
                feedbackControl
            }

        case .queued:
            VStack(spacing: 16) {
                VStack(spacing: 4) {
                    Label("完了しました", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("通信できたときに記録を送ります。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                feedbackControl
            }

        case let .failed(message):
            VStack(spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Button("再試行") { Task { await viewModel.markComplete() } }
            }
            .frame(maxWidth: .infinity)
        }
    }
}
