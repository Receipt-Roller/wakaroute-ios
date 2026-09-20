import Foundation
import Testing
@testable import WakaRouteKit

/// Captured verbatim from https://wakaroute.com/api/v1/english-words on
/// 2026-09-20. Real payload, not a hand-written sample — `the` genuinely has
/// empty `partsOfSpeech` and `pronunciations`.
private let wordPayload = """
{
  "datasetVersion": "2026.1",
  "asOf": "2026-09-19",
  "licenses": [
    { "name": "NGSL 1.2", "spdxId": "CC-BY-SA-4.0",
      "url": "https://creativecommons.org/licenses/by-sa/4.0/",
      "attribution": "New General Service List by Browne, C., Culligan, B., and Phillips, J." },
    { "name": "EJDict-hand", "spdxId": "CC0-1.0",
      "url": "https://creativecommons.org/publicdomain/zero/1.0/",
      "attribution": "English-Japanese Dictionary data EJDict-hand by kujirahand and contributors." }
  ],
  "items": [
    { "id": "en-the", "lemma": "the", "stage": "elementary-review", "recommendedGrade": null,
      "sequence": 1, "frequencyRank": 1, "partsOfSpeech": [],
      "meaningsJa": ["《前述の名詞に付けて》『その』,あの"], "pronunciations": [] },
    { "id": "en-study", "lemma": "study", "stage": "junior-high", "recommendedGrade": 1,
      "sequence": 40, "frequencyRank": 300, "partsOfSpeech": ["verb"],
      "meaningsJa": ["勉強する"], "pronunciations": ["ˈstʌdi"] },
    { "id": "en-rare", "lemma": "rare", "stage": "junior-high", "recommendedGrade": 3,
      "sequence": 900, "frequencyRank": null, "partsOfSpeech": ["adjective"],
      "meaningsJa": ["まれな"], "pronunciations": [] }
  ]
}
"""

/// From https://wakaroute.com/api/v1/kanji on 2026-09-20. Note `license`
/// singular — the kanji set differs from the word set here.
private let kanjiPayload = """
{
  "datasetVersion": "2026.1",
  "asOf": "2026-09-19",
  "license": { "name": "kanji data", "spdxId": "CC-BY-SA-4.0",
               "url": "https://creativecommons.org/licenses/by-sa/4.0/",
               "attribution": "Kanji data contributors." },
  "items": [
    { "id": "jhs-u6b73", "character": "歳", "officialStage": "junior-high", "recommendedGrade": 1,
      "sequence": 1, "strokeCount": 13, "frequencyRank": 269,
      "onReadings": ["サイ", "セイ"], "kunReadings": ["とし", "とせ", "よわい"] }
  ]
}
"""

private struct StubHTTP: HTTPClient {
    let status: Int
    let body: Data
    let headers: [String: String]

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        HTTPResponse(status: status, body: body, headers: HTTPHeaders(headers))
    }
}

private let environment = AppEnvironment.production

private func day(_ text: String) -> Date {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = .current
    return formatter.date(from: text)!
}

@Suite("Cards")
struct CardTests {

    // MARK: - Decoding the real payloads

    @Test("The word set decodes, licences and all")
    func decodesWords() async throws {
        let client = CardCatalogClient(
            http: StubHTTP(status: 200, body: Data(wordPayload.utf8), headers: ["ETag": "\"english-words-2026.1\""]),
            environment: environment,
            now: { day("2026-09-20") }
        )

        guard case let .updated(catalog) = try await client.words(knownEntityTag: nil) else {
            Issue.record("expected an updated catalogue"); return
        }

        #expect(catalog.datasetVersion == "2026.1")
        #expect(catalog.asOf == "2026-09-19")
        #expect(catalog.cards.count == 3)
        #expect(catalog.entityTag == "\"english-words-2026.1\"")
        // Both licences must survive: CC BY-SA obliges us to show them.
        #expect(catalog.licenses.count == 2)
        #expect(catalog.licenses.map(\.spdxId) == ["CC-BY-SA-4.0", "CC0-1.0"])
    }

    @Test("A word with no part of speech or pronunciation still decodes")
    func decodesSparseWord() async throws {
        let client = CardCatalogClient(
            http: StubHTTP(status: 200, body: Data(wordPayload.utf8), headers: [:]),
            environment: environment
        )
        guard case let .updated(catalog) = try await client.words(knownEntityTag: nil) else { return }

        let the = try #require(catalog.cards.first { $0.id == "en-the" })
        #expect(the.partsOfSpeech.isEmpty)
        #expect(the.pronunciations.isEmpty)
        #expect(the.recommendedGrade == nil)
    }

    @Test("The kanji set carries one licence, not a list")
    func decodesKanji() async throws {
        let client = CardCatalogClient(
            http: StubHTTP(status: 200, body: Data(kanjiPayload.utf8), headers: ["etag": "\"kanji-2026.1\""]),
            environment: environment
        )

        guard case let .updated(catalog) = try await client.kanji(knownEntityTag: nil) else {
            Issue.record("expected an updated catalogue"); return
        }

        let kanji = try #require(catalog.cards.first)
        #expect(kanji.character == "歳")
        // A kanji has several readings and a card showing one would be wrong.
        #expect(kanji.onReadings == ["サイ", "セイ"])
        #expect(kanji.kunReadings == ["とし", "とせ", "よわい"])
        #expect(catalog.licenses.count == 1)
        // Header case varies by server; the lookup must not care.
        #expect(catalog.entityTag == "\"kanji-2026.1\"")
    }

    @Test("304 means the stored copy stands")
    func notModified() async throws {
        let client = CardCatalogClient(
            http: StubHTTP(status: 304, body: Data(), headers: [:]),
            environment: environment
        )
        #expect(try await client.words(knownEntityTag: "\"english-words-2026.1\"") == .unchanged)
    }

    // MARK: - Storage

    @Test("A saved set reads back after a restart")
    func savesAndReloads() throws {
        // Writing is not the same as reading. This app has shipped a store
        // that wrote correctly and read back nothing.
        let store = try CardFileStore<WordCard>(filename: "test-cards-\(UUID().uuidString).json")
        #expect(try store.load() == nil)

        let catalog = CardCatalog(
            datasetVersion: "2026.1", asOf: "2026-09-19", licenses: [],
            cards: [WordCard](), entityTag: "\"x\"", fetchedAt: day("2026-09-20")
        )
        try store.save(catalog)

        let reloaded = try #require(try store.load())
        #expect(reloaded.datasetVersion == "2026.1")
        #expect(reloaded.entityTag == "\"x\"")
    }

    // MARK: - Ordering

    @Test("Cards come out commonest first, and unranked ones go last")
    func ordersByFrequency() async throws {
        let cards = try await loadWords()
        let ordered = CardDeck.inScope(cards, scope: .init())

        #expect(ordered.map(\.id) == ["en-the", "en-study", "en-rare"])
    }

    @Test("A year filter keeps a 中3 student away from 'the'")
    func filtersByGrade() async throws {
        let cards = try await loadWords()
        let ordered = CardDeck.inScope(cards, scope: .init(grade: 3))

        #expect(ordered.map(\.id) == ["en-rare"])
    }

    @Test("A stage filter separates 小学校の復習 from 中学")
    func filtersByStage() async throws {
        let cards = try await loadWords()
        #expect(CardDeck.inScope(cards, scope: .init(stage: "elementary-review")).map(\.id) == ["en-the"])
    }

    // MARK: - Spaced repetition

    @Test("A correct answer moves the card up; a wrong one sends it back")
    func boxesMoveOnAnswers() {
        let first = CardScheduler.answering(nil, correct: true, on: day("2026-09-20"))
        #expect(first.box == 1)

        let second = CardScheduler.answering(first, correct: true, on: day("2026-09-21"))
        #expect(second.box == 2)

        let wrong = CardScheduler.answering(second, correct: false, on: day("2026-09-22"))
        #expect(wrong.box == 0)
    }

    @Test("One correct answer does not mean the card is learned")
    func oneRightAnswerIsNotLearning() {
        var review = CardScheduler.answering(nil, correct: true, on: day("2026-09-20"))
        #expect(!review.isLearned)

        for offset in 1...4 {
            review = CardScheduler.answering(review, correct: true, on: day("2026-09-2\(offset)"))
        }
        #expect(review.isLearned)
    }

    @Test("A card is not shown again until its interval has passed")
    func waitsForTheInterval() {
        let review = CardReview(box: 2, reviewedOn: day("2026-09-20"))   // 3 日あける

        #expect(!CardScheduler.isDue(review, on: day("2026-09-21")))
        #expect(!CardScheduler.isDue(review, on: day("2026-09-22")))
        #expect(CardScheduler.isDue(review, on: day("2026-09-23")))
    }

    @Test("An unseen card is always due; a learned one never is")
    func newAndLearnedCards() {
        #expect(CardScheduler.isDue(nil, on: day("2026-09-20")))
        #expect(!CardScheduler.isDue(CardReview(box: 5, reviewedOn: day("2026-09-20")), on: day("2026-09-21")))
    }

    @Test("A review dated in the future means the clock moved, not that we wait years")
    func toleratesAClockThatWentBackwards() {
        let review = CardReview(box: 1, reviewedOn: day("2027-01-01"))
        #expect(CardScheduler.isDue(review, on: day("2026-09-20")))
    }

    // MARK: - A sitting

    @Test("Due cards come before new ones, so a backlog is not buried")
    func dueBeforeNew() async throws {
        let cards = try await loadWords()
        var progress = CardProgress()
        // 'rare' was answered and is due again; 'the' and 'study' are untouched.
        progress.record(CardReview(box: 1, reviewedOn: day("2026-09-01")), for: "en-rare")

        let session = CardDeck.session(
            from: cards, scope: .init(), progress: progress, on: day("2026-09-20")
        )

        #expect(session.first?.id == "en-rare")
        #expect(session.map(\.id) == ["en-rare", "en-the", "en-study"])
    }

    @Test("A sitting is capped, so the deck can be finished")
    func sessionIsCapped() async throws {
        let cards = try await loadWords()
        let session = CardDeck.session(
            from: cards, scope: .init(), progress: CardProgress(), on: day("2026-09-20"), size: 2
        )
        #expect(session.count == 2)
    }

    @Test("Progress counts what has been learned, not what has been touched")
    func countsLearned() {
        var progress = CardProgress()
        progress.record(CardReview(box: 5, reviewedOn: day("2026-09-20")), for: "a")
        progress.record(CardReview(box: 2, reviewedOn: day("2026-09-20")), for: "b")

        #expect(progress.startedCount == 2)
        #expect(progress.learnedCount == 1)
    }

    private func loadWords() async throws -> [WordCard] {
        let client = CardCatalogClient(
            http: StubHTTP(status: 200, body: Data(wordPayload.utf8), headers: [:]),
            environment: environment
        )
        guard case let .updated(catalog) = try await client.words(knownEntityTag: nil) else { return [] }
        return catalog.cards
    }
}

extension CardTests {
    @Test("A word with no Japanese meaning is left out, not shown blank")
    func excludesCardsWithNoBack() {
        let blank = try! JSONDecoder().decode(WordCard.self, from: Data("""
        { "id": "en-email", "lemma": "email", "stage": "junior-high", "recommendedGrade": 1,
          "sequence": 2, "frequencyRank": 2, "partsOfSpeech": [], "meaningsJa": [], "pronunciations": [] }
        """.utf8))
        let usable = try! JSONDecoder().decode(WordCard.self, from: Data("""
        { "id": "en-study", "lemma": "study", "stage": "junior-high", "recommendedGrade": 1,
          "sequence": 1, "frequencyRank": 1, "partsOfSpeech": [], "meaningsJa": ["勉強する"], "pronunciations": [] }
        """.utf8))

        #expect(CardDeck.inScope([blank, usable], scope: .init()).map(\.id) == ["en-study"])
    }
}

@Suite("Card library")
struct CardLibraryTests {

    private func library(status: Int, body: String, etag: String = "") -> CardLibrary {
        CardLibrary(
            client: CardCatalogClient(
                http: StubHTTP(status: status, body: Data(body.utf8), headers: ["ETag": etag]),
                environment: AppEnvironment.production
            ),
            wordStore: InMemoryCardStore<WordCard>(),
            kanjiStore: InMemoryCardStore<KanjiCard>(),
            subjectStore: InMemoryCardStore<SubjectCard>(),
            progressStore: InMemoryCardProgressStore()
        )
    }

    @Test("An answer is saved the moment it is given")
    func recordsImmediately() {
        let library = self.library(status: 200, body: wordPayload)

        let progress = library.record(cardId: "en-the", correct: true, on: day("2026-09-20"))
        #expect(progress["en-the"]?.box == 1)
        // Read back through the store, not the returned value.
        #expect(library.progress()["en-the"]?.box == 1)
    }

    @Test("A stored set is used when the network fails")
    func fallsBackToTheStoredSet() async throws {
        let store = InMemoryCardStore<WordCard>(
            CardCatalog(
                datasetVersion: "2026.1", asOf: "2026-09-19", licenses: [],
                cards: [], entityTag: "\"english-words-2026.1\"", fetchedAt: day("2026-09-20")
            )
        )
        let library = CardLibrary(
            client: CardCatalogClient(
                http: StubHTTP(status: 500, body: Data(), headers: [:]),
                environment: AppEnvironment.production
            ),
            wordStore: store,
            kanjiStore: InMemoryCardStore<KanjiCard>(),
            subjectStore: InMemoryCardStore<SubjectCard>(),
            progressStore: InMemoryCardProgressStore()
        )

        // Being offline must not empty the deck.
        let catalog = try await library.words()
        #expect(catalog.datasetVersion == "2026.1")
    }

    @Test("A first run with no network has nothing to show, and says so")
    func firstRunWithNoNetworkFails() async {
        let library = self.library(status: 500, body: "")
        await #expect(throws: (any Error).self) { try await library.words() }
    }
}

/// Captured verbatim from https://wakaroute.com/api/v1/study-cards on
/// 2026-09-20.
private let subjectPayload = """
{
  "datasetVersion": "2026.2",
  "asOf": "2026-09-20",
  "license": { "name": "WakaRoute original study cards", "spdxId": "Apache-2.0",
               "url": "https://www.apache.org/licenses/LICENSE-2.0",
               "attribution": "Copyright Receipt Roller, Inc." },
  "items": [
    { "id": "math-numbers-absolute-value", "subject": "math", "domain": "numbers",
      "recommendedGrade": 1, "cardType": "term",
      "prompt": "絶対値とは何？", "answer": "数直線上で0からその数までの距離。",
      "explanation": "距離なので絶対値は0以上になる。", "tags": ["正負の数"], "sourceRefs": ["mext"] },
    { "id": "science-energy-work", "subject": "science", "domain": "energy",
      "recommendedGrade": 3, "cardType": "formula-unit",
      "prompt": "仕事の公式は？", "answer": "力×距離", "explanation": "単位はJ。",
      "tags": ["仕事"], "sourceRefs": ["mext"] },
    { "id": "social-studies-history-century", "subject": "social-studies", "domain": "history",
      "recommendedGrade": 1, "cardType": "chronology",
      "prompt": "西暦645年は何世紀？", "answer": "7世紀",
      "explanation": "年を100で割って切り上げる。", "tags": ["年代"], "sourceRefs": ["mext"] }
  ]
}
"""

@Suite("Subject cards")
struct SubjectCardTests {

    private func load() async throws -> [SubjectCard] {
        let client = CardCatalogClient(
            http: StubHTTP(status: 200, body: Data(subjectPayload.utf8), headers: ["ETag": "\"study-cards-2026.2\""]),
            environment: AppEnvironment.production
        )
        guard case let .updated(catalog) = try await client.subjectCards(knownEntityTag: nil) else { return [] }
        return catalog.cards
    }

    @Test("The 数学・理科・社会 set decodes with its own licence")
    func decodes() async throws {
        let client = CardCatalogClient(
            http: StubHTTP(status: 200, body: Data(subjectPayload.utf8), headers: [:]),
            environment: AppEnvironment.production
        )
        guard case let .updated(catalog) = try await client.subjectCards(knownEntityTag: nil) else {
            Issue.record("expected a catalogue"); return
        }

        #expect(catalog.cards.count == 3)
        #expect(catalog.datasetVersion == "2026.2")
        // Written by WakaRoute, so Apache-2.0 rather than the CC BY-SA of the
        // word and kanji data. Still has to be shown.
        #expect(catalog.licenses.first?.spdxId == "Apache-2.0")
    }

    @Test("Published order is kept, because these carry no frequency ranking")
    func keepsPublishedOrder() async throws {
        let cards = try await load()
        #expect(cards.map(\.order) == [0, 1, 2])
        #expect(CardDeck.inScope(cards, scope: .init()).map(\.id) == cards.map(\.id))
    }

    @Test("A card with no answer is left out")
    func excludesAnswerless() throws {
        let blank = try JSONDecoder().decode(SubjectCard.self, from: Data("""
        { "id": "x", "subject": "math", "domain": "numbers", "recommendedGrade": 1,
          "cardType": "term", "prompt": "問い", "answer": "", "tags": [] }
        """.utf8))
        #expect(!blank.isStudiable)
        #expect(CardDeck.inScope([blank], scope: .init()).isEmpty)
    }

    @Test("A year filter works the same as it does for words")
    func filtersByGrade() async throws {
        let cards = try await load()
        #expect(CardDeck.inScope(cards, scope: .init(grade: 3)).map(\.id) == ["science-energy-work"])
    }

    @Test("A stored card round-trips, order included")
    func roundTrips() async throws {
        let cards = try await load()
        // Through the file store, not the in-memory one: the point is whether
        // the order survives being encoded, and an in-memory store never
        // encodes anything.
        let store = try CardFileStore<SubjectCard>(filename: "test-subject-\(UUID().uuidString).json")
        try store.save(CardCatalog(
            datasetVersion: "2026.2", asOf: "2026-09-20", licenses: [],
            cards: cards, entityTag: "\"study-cards-2026.2\"", fetchedAt: Date()
        ))

        let reloaded = try #require(try store.load())
        #expect(reloaded.cards.map(\.id) == cards.map(\.id))
        // The order is not in the payload, so it has to be written down. Lose
        // it and the deck silently re-sorts by id on the next launch.
        #expect(reloaded.cards.map(\.order) == [0, 1, 2])
        #expect(CardDeck.inScope(reloaded.cards, scope: .init()).map(\.id) == cards.map(\.id))
    }
}
