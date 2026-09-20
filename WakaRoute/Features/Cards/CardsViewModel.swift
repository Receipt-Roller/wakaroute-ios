import Foundation
import SwiftUI
import WakaRouteKit

/// 単語カード・漢字カード.
/// One downloaded set and what it is published under.
struct CardDataSource: Identifiable {
    var id: String { title }
    let title: String
    let asOf: String
    let licenses: [CardLicense]
}

@MainActor
@Observable
final class CardsViewModel {
    enum State {
        case loading
        case failed(String)
        case ready
    }

    private let library: CardLibrary

    private(set) var state: State = .loading
    private(set) var words: [WordCard] = []
    private(set) var kanji: [KanjiCard] = []
    private(set) var subjectCards: [SubjectCard] = []
    /// One entry per downloaded set, so each licence is shown against the data
    /// it actually covers — and each set against its own 基準日.
    private(set) var datasets: [CardDataSource] = []
    private(set) var progress = CardProgress()


    /// The range the student is working on. Defaults to everything so nothing
    /// is hidden before they have chosen anything.
    var scope = CardDeck.Scope()

    init(library: CardLibrary) {
        self.library = library
    }

    func load() async {
        state = .loading
        do {
            async let wordCatalog = library.words()
            async let kanjiCatalog = library.kanji()
            async let subjectCatalog = library.subjectCards()

            let (fetchedWords, fetchedKanji, fetchedSubjects) =
                try await (wordCatalog, kanjiCatalog, subjectCatalog)
            words = fetchedWords.cards
            kanji = fetchedKanji.cards
            subjectCards = fetchedSubjects.cards
            datasets = [
                CardDataSource(title: "単語カード", asOf: fetchedWords.asOf, licenses: fetchedWords.licenses),
                CardDataSource(title: "漢字カード", asOf: fetchedKanji.asOf, licenses: fetchedKanji.licenses),
                CardDataSource(
                    title: "数学・理科・社会カード",
                    asOf: fetchedSubjects.asOf,
                    licenses: fetchedSubjects.licenses
                )
            ]
            progress = library.progress()
            state = .ready
        } catch {
            state = .failed("カードを読み込めませんでした。通信を確かめて、もう一度お試しください。")
        }
    }

    /// The cards for one 教科, in published order.
    func cards(forSubject subject: String) -> [SubjectCard] {
        subjectCards.filter { $0.subject == subject }
    }

    func session<Card: StudyCard>(from cards: [Card], on day: Date = Date()) -> [Card] {
        CardDeck.session(from: cards, scope: scope, progress: progress, on: day)
    }

    func answer(cardId: String, correct: Bool) {
        progress = library.record(cardId: cardId, correct: correct)
    }

    func learnedCount<Card: StudyCard>(in cards: [Card]) -> Int {
        CardDeck.inScope(cards, scope: scope).count { progress[$0.id]?.isLearned == true }
    }

    func startedCount<Card: StudyCard>(in cards: [Card]) -> Int {
        CardDeck.inScope(cards, scope: scope).count { progress[$0.id] != nil }
    }

    func scopedCount<Card: StudyCard>(in cards: [Card]) -> Int {
        CardDeck.inScope(cards, scope: scope).count
    }
}
