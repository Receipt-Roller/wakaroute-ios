import Foundation

public protocol CardProgressStoring: Sendable {
    func load() throws -> CardProgress
    func save(_ progress: CardProgress) throws
}

public struct CardProgressFileStore: CardProgressStoring {
    private let url: URL

    public init(filename: String = "card-progress.json") throws {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        url = directory.appending(path: filename)
    }

    public func load() throws -> CardProgress {
        guard FileManager.default.fileExists(atPath: url.filePath) else { return CardProgress() }
        return try JSONDecoder.wakaRoute.decode(CardProgress.self, from: Data(contentsOf: url))
    }

    public func save(_ progress: CardProgress) throws {
        try JSONEncoder.wakaRoute.encode(progress).write(to: url, options: .atomic)
    }
}

public final class InMemoryCardProgressStore: CardProgressStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var progress = CardProgress()

    public init() {}
    public func load() throws -> CardProgress { lock.withLock { progress } }
    public func save(_ new: CardProgress) throws { lock.withLock { progress = new } }
}

/// The card sets and what the student has done with them.
///
/// Always answers from the device first. The network is only ever asked
/// whether the stored copy is stale, so being offline costs nothing — which is
/// the point of downloading the whole set.
public struct CardLibrary: Sendable {
    private let client: CardCatalogClient
    private let wordStore: any CardStoring<WordCard>
    private let kanjiStore: any CardStoring<KanjiCard>
    private let progressStore: any CardProgressStoring

    public init(
        client: CardCatalogClient,
        wordStore: any CardStoring<WordCard>,
        kanjiStore: any CardStoring<KanjiCard>,
        progressStore: any CardProgressStoring
    ) {
        self.client = client
        self.wordStore = wordStore
        self.kanjiStore = kanjiStore
        self.progressStore = progressStore
    }

    public func words() async throws -> CardCatalog<WordCard> {
        try await refreshed(
            stored: try? wordStore.load(),
            fetch: { try await client.words(knownEntityTag: $0) },
            save: { try? wordStore.save($0) }
        )
    }

    public func kanji() async throws -> CardCatalog<KanjiCard> {
        try await refreshed(
            stored: try? kanjiStore.load(),
            fetch: { try await client.kanji(knownEntityTag: $0) },
            save: { try? kanjiStore.save($0) }
        )
    }

    public func progress() -> CardProgress {
        (try? progressStore.load()) ?? CardProgress()
    }

    /// Records an answer. Saved immediately — a session interrupted by a
    /// closed app must not lose what the student just did.
    @discardableResult
    public func record(
        cardId: String,
        correct: Bool,
        on day: Date = Date(),
        calendar: Calendar = .current
    ) -> CardProgress {
        var progress = self.progress()
        let review = CardScheduler.answering(
            progress[cardId], correct: correct, on: day, calendar: calendar
        )
        progress.record(review, for: cardId)
        try? progressStore.save(progress)
        return progress
    }

    private func refreshed<Card>(
        stored: CardCatalog<Card>?,
        fetch: (String?) async throws -> CardRefresh<Card>,
        save: (CardCatalog<Card>) -> Void
    ) async throws -> CardCatalog<Card> {
        do {
            switch try await fetch(stored?.entityTag) {
            case .unchanged:
                guard let stored else { throw APIError.unknown("304 with nothing stored.") }
                return stored
            case let .updated(catalog):
                save(catalog)
                return catalog
            }
        } catch {
            // Offline, or the server is having a bad day. A stored set is still
            // a complete set; only a first run has nothing to fall back on.
            guard let stored else { throw error }
            return stored
        }
    }
}
