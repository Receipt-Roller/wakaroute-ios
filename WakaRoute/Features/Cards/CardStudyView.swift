import SwiftUI
import WakaRouteKit

/// One sitting with a deck.
///
/// The card turns over on a tap; 「わかった」 and 「まだ」 are only offered once
/// the back has been seen, because grading a card you have not read is not an
/// answer.
struct CardStudyView<Card: StudyCard, Front: View, Back: View>: View {
    let title: String
    let cards: [Card]
    let viewModel: CardsViewModel
    @ViewBuilder let front: (Card) -> Front
    @ViewBuilder let back: (Card) -> Back

    @State private var index = 0
    @State private var isShowingBack = false
    @State private var answered = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if cards.isEmpty {
                ContentUnavailableView {
                    Label("いまは出すカードがありません", systemImage: "checkmark.circle")
                } description: {
                    Text("この範囲のカードは今日のぶんが終わっています。範囲を変えるか、また明日どうぞ。")
                }
            } else if index >= cards.count {
                finished
            } else {
                card(cards[index])
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func card(_ card: Card) -> some View {
        VStack(spacing: 20) {
            ScrollView {
                VStack(spacing: 20) {
                    Text("\(index + 1) / \(cards.count)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(cards.count) 枚中 \(index + 1) 枚目")

                    Button {
                        reveal()
                    } label: {
                        VStack(spacing: 18) {
                            front(card)

                            if isShowingBack {
                                Divider()
                                back(card)
                            } else {
                                Text("タップして答えを見る")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        // Without this the meaning truncates at the larger text
                        // sizes, leaving a card with no answer on it.
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                        .padding(24)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(isShowingBack ? "" : "ひらいて答えを見る")
                }
                .padding(20)
                .readableWidth()
            }

            if isShowingBack {
                answers(for: card)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                    .readableWidth()
            }
        }
    }

    /// Side by side normally; stacked once the text is large enough that two
    /// buttons in a row would wrap a character at a time.
    private func answers(for card: Card) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))

        return layout {
            answerButton("まだ", symbol: "arrow.counterclockwise", correct: false, card: card)
            answerButton("わかった", symbol: "checkmark", correct: true, card: card)
        }
    }

    private func answerButton(_ label: String, symbol: String, correct: Bool, card: Card) -> some View {
        Button {
            viewModel.answer(cardId: card.id, correct: correct)
            answered += 1
            advance()
        } label: {
            // Never colour alone: the word and the symbol both carry it.
            Label(label, systemImage: symbol)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(correct ? .accentColor : .secondary)
    }

    private var finished: some View {
        ContentUnavailableView {
            Label("おつかれさま", systemImage: "checkmark.circle.fill")
        } description: {
            Text("\(answered) 枚やりました。わかったカードも、間をあけてもう一度出ます。\n5回続けてわかると「おぼえた」になります。")
        }
    }

    private func reveal() {
        guard !isShowingBack else { return }
        // The one setting a student turns on has to hold everywhere.
        if reduceMotion {
            isShowingBack = true
        } else {
            withAnimation(.easeInOut(duration: 0.15)) { isShowingBack = true }
        }
    }

    private func advance() {
        isShowingBack = false
        index += 1
    }
}

struct WordStudyView: View {
    let viewModel: CardsViewModel
    @State private var deck: [WordCard] = []

    var body: some View {
        CardStudyView(title: "単語カード", cards: deck, viewModel: viewModel) { card in
            VStack(spacing: 6) {
                Text(card.lemma)
                    .font(.largeTitle.weight(.semibold))
                    .multilineTextAlignment(.center)
                if let pronunciation = card.pronunciations.first {
                    Text(pronunciation).font(.callout).foregroundStyle(.secondary)
                }
            }
        } back: { card in
            VStack(alignment: .leading, spacing: 10) {
                // Dictionary wording, and long. The first sense is the one a
                // 中学生 needs; the rest are there but out of the way.
                if let first = card.meaningsJa.first {
                    Text(first).font(.title3)
                }
                if card.meaningsJa.count > 1 {
                    DisclosureGroup("ほかの意味 \(card.meaningsJa.count - 1) 件") {
                        ForEach(Array(card.meaningsJa.dropFirst().enumerated()), id: \.offset) { _, meaning in
                            Text(meaning)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .font(.footnote)
                }
                if !card.partsOfSpeech.isEmpty {
                    Text(card.partsOfSpeech.joined(separator: "・"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { if deck.isEmpty { deck = viewModel.session(from: viewModel.words) } }
    }
}

struct KanjiStudyView: View {
    let viewModel: CardsViewModel
    @State private var deck: [KanjiCard] = []

    var body: some View {
        CardStudyView(title: "漢字カード", cards: deck, viewModel: viewModel) { card in
            Text(card.character)
                .font(.system(size: 96))
                .minimumScaleFactor(0.4)
                .accessibilityLabel("漢字 \(card.character)")
        } back: { card in
            VStack(alignment: .leading, spacing: 10) {
                // A kanji has several readings; showing one would teach a
                // half-truth.
                if !card.onReadings.isEmpty {
                    LabeledContent("音読み", value: card.onReadings.joined(separator: "・"))
                }
                if !card.kunReadings.isEmpty {
                    LabeledContent("訓読み", value: card.kunReadings.joined(separator: "・"))
                }
                if let strokes = card.strokeCount {
                    LabeledContent("画数", value: "\(strokes) 画")
                }
            }
            .font(.title3)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { if deck.isEmpty { deck = viewModel.session(from: viewModel.kanji) } }
    }
}
