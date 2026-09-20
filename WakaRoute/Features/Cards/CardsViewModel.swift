import Foundation
import SwiftUI
import WakaRouteKit

/// 単語カード・漢字カード.
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
    private(set) var licenses: [CardLicense] = []
    private(set) var progress = CardProgress()
    /// When the stored copy was last confirmed current, for the 「最終更新」 line.
    private(set) var asOf = ""

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

            let (fetchedWords, fetchedKanji) = try await (wordCatalog, kanjiCatalog)
            words = fetchedWords.cards
            kanji = fetchedKanji.cards
            licenses = fetchedWords.licenses + fetchedKanji.licenses
            asOf = fetchedWords.asOf
            progress = library.progress()
            state = .ready
        } catch {
            state = .failed("カードを読み込めませんでした。通信を確かめて、もう一度お試しください。")
        }
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
