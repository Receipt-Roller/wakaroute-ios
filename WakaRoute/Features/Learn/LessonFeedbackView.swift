import Observation
import SwiftUI
import WakaRouteKit

@MainActor
@Observable
final class LessonFeedbackViewModel {
    enum Phase: Equatable {
        case asking
        /// 「むずかしかった」 chosen; the reasons are now showing.
        case explaining
        case sending
        case done(understood: Bool)
        /// Kept on the device until the network comes back.
        case queued(understood: Bool)
    }

    private(set) var phase: Phase = .asking
    private(set) var reasons: Set<LessonFeedback.Reason> = []
    var comment = ""

    let lessonId: String
    private let content: ContentClient
    private let queue: LearningActionQueue?

    /// One key per opinion. Changing an answer is a new opinion, not a retry of
    /// the old one, so re-rating gets a fresh key and replaces what was there.
    private var idempotencyKey = UUID().uuidString

    init(lessonId: String, content: ContentClient, queue: LearningActionQueue? = nil) {
        self.lessonId = lessonId
        self.content = content
        self.queue = queue
    }

    /// 「わかった」 finishes in one tap. Most answers are this one, and putting
    /// friction here would cost the response rate on all of them.
    func understood() async {
        await send(LessonFeedback(understood: true))
    }

    func didNotUnderstand() {
        phase = .explaining
    }

    var remainingCharacters: Int {
        LessonFeedback.commentLimit - comment.count
    }

    /// Only shown once it is worth knowing. A counter present from the first
    /// character reads as a target to fill.
    var isCommentNearLimit: Bool {
        remainingCharacters <= 100
    }

    func toggle(_ reason: LessonFeedback.Reason) {
        if reasons.contains(reason) { reasons.remove(reason) } else { reasons.insert(reason) }
    }

    func submitDifficulty() async {
        let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        await send(
            LessonFeedback(
                understood: false,
                // Sorted so the same set of taps always sends the same body.
                reasons: reasons.sorted { $0.rawValue < $1.rawValue },
                comment: text.isEmpty ? nil : text
            )
        )
    }

    /// Lets a student change their mind after re-reading.
    func rateAgain() {
        idempotencyKey = UUID().uuidString
        reasons = []
        comment = ""
        phase = .asking
    }

    private func send(_ feedback: LessonFeedback) async {
        phase = .sending
        do {
            try await content.submitFeedback(
                lessonId: lessonId,
                feedback: feedback,
                idempotencyKey: idempotencyKey
            )
            phase = .done(understood: feedback.understood)
        } catch {
            // They told us what they thought; losing it because of a tunnel
            // would be losing something they actually did.
            if let queue {
                await queue.enqueue(
                    PendingAction(
                        kind: .feedback,
                        lessonId: lessonId,
                        feedback: feedback,
                        idempotencyKey: idempotencyKey
                    )
                )
                phase = .queued(understood: feedback.understood)
            } else {
                phase = .done(understood: feedback.understood)
            }
        }
    }
}

/// Asked after a lesson is finished, and never in the way.
///
/// Not a modal, not required, no popup. A student who is asked to rate every
/// lesson before they can move on will tap through without reading — and
/// answers given to make a dialog go away are worse than no answers at all.
/// This appears quietly below the completion button and is easy to ignore.
struct LessonFeedbackView: View {
    @State var viewModel: LessonFeedbackViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch viewModel.phase {
            case .asking:
                askingSection

            case .explaining:
                explainingSection

            case .sending:
                HStack { Spacer(); ProgressView(); Spacer() }

            case let .done(understood):
                thanks(understood: understood, queued: false)

            case let .queued(understood):
                thanks(understood: understood, queued: true)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
    }

    private var askingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("このレッスン、どうだった？")
                .font(.subheadline.weight(.medium))

            AdaptiveRow(spacing: 10) {
                Button("わかった") {
                    Task { await viewModel.understood() }
                }
                .buttonStyle(.bordered)

                Button("むずかしかった") {
                    viewModel.didNotUnderstand()
                }
                .buttonStyle(.bordered)

                Spacer(minLength: 0)
            }
        }
    }

    private var explainingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("どこがむずかしかった？")
                .font(.subheadline.weight(.medium))
            Text("えらばなくても送れます。")
                .font(.caption)
                .foregroundStyle(.secondary)

            ReasonChips(
                selected: viewModel.reasons,
                toggle: { viewModel.toggle($0) }
            )

            // Deliberately last and unlabelled as required. Most students will
            // tap a chip and stop, which is the point of having chips at all.
            VStack(alignment: .leading, spacing: 4) {
                Text("もっと知りたいことがあれば（任意）")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("例: 数直線のところをもっとくわしく", text: $viewModel.comment, axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)

                // The server refuses over 1000 characters with a 400, which the
                // queue treats as permanent — so the count appears before they
                // get there rather than after the answer is lost.
                if viewModel.isCommentNearLimit {
                    Text("のこり \(viewModel.remainingCharacters) 文字")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(viewModel.remainingCharacters < 0 ? .orange : .secondary)
                }

                // Stated where it is written, not buried in a policy. A 中学生
                // will not think of this on their own.
                Label("名前や学校名は書かないでください。", systemImage: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await viewModel.submitDifficulty() }
            } label: {
                Text("送る").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.remainingCharacters < 0)
        }
    }

    private func thanks(understood: Bool, queued: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                understood ? "ありがとう。" : "ありがとう。内容を見直します。",
                systemImage: "checkmark.circle.fill"
            )
            .font(.subheadline)
            .foregroundStyle(.green)

            if queued {
                Text("通信できたときに送ります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("答えを変える") { viewModel.rateAgain() }
                .font(.caption)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Tap-only reasons. A 中学生 will not write a sentence, so a free-text-only
/// form collects almost nothing and cannot be counted; these can be.
private struct ReasonChips: View {
    let selected: Set<LessonFeedback.Reason>
    let toggle: (LessonFeedback.Reason) -> Void

    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(LessonFeedback.Reason.allCases) { reason in
                let isOn = selected.contains(reason)
                Button {
                    toggle(reason)
                } label: {
                    Text(reason.label)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(
                            Capsule().fill(isOn ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12))
                        )
                        .overlay(
                            // Selection is not carried by colour alone — §8.
                            Capsule().strokeBorder(isOn ? Color.accentColor : .clear, lineWidth: 1.5)
                        )
                        .foregroundStyle(isOn ? Color.accentColor : .primary)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? [.isSelected] : [])
            }
        }
    }
}
