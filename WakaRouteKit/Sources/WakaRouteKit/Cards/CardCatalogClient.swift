import Foundation

/// What a refresh found.
public enum CardRefresh<Card: Codable & Sendable & Equatable>: Sendable, Equatable {
    /// The server confirmed the stored copy is current (304).
    case unchanged
    case updated(CardCatalog<Card>)
}

/// Fetches the 単語 and 漢字 card sets from wakaroute.com.
///
/// These live on **wakaroute.com, not MANABU2**, and need no token — the same
/// arrangement as 高校検索. Each set comes down whole in one response
/// (2,450 words, 1,110 kanji; 240 KB gzipped together) with an `ETag`, so the
/// device keeps the lot and asks only whether it has changed. That is what
/// makes the cards work with no signal.
public struct CardCatalogClient: Sendable {
    private let http: HTTPClient
    private let environment: AppEnvironment
    private let now: @Sendable () -> Date

    public init(
        http: HTTPClient,
        environment: AppEnvironment,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.http = http
        self.environment = environment
        self.now = now
    }

    public func words(knownEntityTag: String?) async throws -> CardRefresh<WordCard> {
        try await refresh(path: "/api/v1/english-words/dataset", knownEntityTag: knownEntityTag) { data, tag in
            let decoded = try JSONDecoder().decode(WordDatasetResponse.self, from: data)
            return CardCatalog(
                datasetVersion: decoded.datasetVersion ?? "",
                asOf: decoded.asOf ?? "",
                licenses: decoded.licenses ?? [],
                cards: decoded.items ?? [],
                entityTag: tag,
                fetchedAt: now()
            )
        }
    }

    public func kanji(knownEntityTag: String?) async throws -> CardRefresh<KanjiCard> {
        try await refresh(path: "/api/v1/kanji/dataset", knownEntityTag: knownEntityTag) { data, tag in
            let decoded = try JSONDecoder().decode(KanjiDatasetResponse.self, from: data)
            return CardCatalog(
                datasetVersion: decoded.datasetVersion ?? "",
                asOf: decoded.asOf ?? "",
                licenses: [decoded.license].compactMap { $0 },
                cards: decoded.items ?? [],
                entityTag: tag,
                fetchedAt: now()
            )
        }
    }

    public func subjectCards(knownEntityTag: String?) async throws -> CardRefresh<SubjectCard> {
        try await refresh(path: "/api/v1/study-cards/dataset", knownEntityTag: knownEntityTag) { data, tag in
            let decoded = try JSONDecoder().decode(SubjectDatasetResponse.self, from: data)
            let ordered = (decoded.items ?? []).enumerated().map { offset, card -> SubjectCard in
                var card = card
                card.order = offset
                return card
            }
            return CardCatalog(
                datasetVersion: decoded.datasetVersion ?? "",
                asOf: decoded.asOf ?? "",
                licenses: [decoded.license].compactMap { $0 },
                cards: ordered,
                entityTag: tag,
                fetchedAt: now()
            )
        }
    }

    private func refresh<Card>(
        path: String,
        knownEntityTag: String?,
        decode: (Data, String) throws -> CardCatalog<Card>
    ) async throws -> CardRefresh<Card> {
        var headers: [String: String] = [:]
        if let knownEntityTag, !knownEntityTag.isEmpty {
            headers["If-None-Match"] = knownEntityTag
        }

        let response = try await http.send(
            HTTPRequest(
                method: .get,
                url: environment.wakarouteBaseURL.appending(path: path),
                headers: headers
            )
        )

        if response.status == 304 { return .unchanged }
        guard (200..<300).contains(response.status) else {
            throw APIError.http(status: response.status, problem: nil)
        }

        return .updated(try decode(response.body, response.headers["ETag"] ?? ""))
    }
}
