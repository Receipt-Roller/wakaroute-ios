import Foundation

/// A licence the card data is published under.
///
/// NGSL and the kanji data are **CC BY-SA**, so showing the cards without
/// showing this is a licence breach. The API returns the wording to display,
/// which is why `attribution` is carried verbatim rather than composed here.
public struct CardLicense: Decodable, Sendable, Equatable {
    public let name: String?
    public let spdxId: String?
    public let url: String?
    public let attribution: String?
}

/// 英単語カード.
public struct WordCard: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let lemma: String
    /// `elementary-review` — 小学校の復習 — or `junior-high`.
    public let stage: String?
    /// 1–3, or nil for the 小学校 review words, which belong to no 中学 year.
    public let recommendedGrade: Int?
    public let sequence: Int?
    /// Lower is commoner. `the` is 1.
    public let frequencyRank: Int?
    public let partsOfSpeech: [String]
    /// Dictionary wording, and often long. Frequently more than one sense.
    public let meaningsJa: [String]
    public let pronunciations: [String]

    private enum CodingKeys: String, CodingKey {
        case id, lemma, stage, recommendedGrade, sequence, frequencyRank
        case partsOfSpeech, meaningsJa, pronunciations
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        lemma = try c.decodeIfPresent(String.self, forKey: .lemma) ?? ""
        stage = try c.decodeIfPresent(String.self, forKey: .stage)
        recommendedGrade = try c.decodeIfPresent(FlexibleInt.self, forKey: .recommendedGrade)?.value
        sequence = try c.decodeIfPresent(FlexibleInt.self, forKey: .sequence)?.value
        frequencyRank = try c.decodeIfPresent(FlexibleInt.self, forKey: .frequencyRank)?.value
        partsOfSpeech = try c.decodeIfPresent([String].self, forKey: .partsOfSpeech) ?? []
        meaningsJa = try c.decodeIfPresent([String].self, forKey: .meaningsJa) ?? []
        pronunciations = try c.decodeIfPresent([String].self, forKey: .pronunciations) ?? []
    }
}

/// 漢字カード.
public struct KanjiCard: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let character: String
    public let officialStage: String?
    public let recommendedGrade: Int?
    public let sequence: Int?
    public let frequencyRank: Int?
    public let strokeCount: Int?
    /// A kanji usually has several of each, and a card that shows one is wrong.
    public let onReadings: [String]
    public let kunReadings: [String]

    private enum CodingKeys: String, CodingKey {
        case id, character, officialStage, recommendedGrade, sequence
        case frequencyRank, strokeCount, onReadings, kunReadings
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        character = try c.decodeIfPresent(String.self, forKey: .character) ?? ""
        officialStage = try c.decodeIfPresent(String.self, forKey: .officialStage)
        recommendedGrade = try c.decodeIfPresent(FlexibleInt.self, forKey: .recommendedGrade)?.value
        sequence = try c.decodeIfPresent(FlexibleInt.self, forKey: .sequence)?.value
        frequencyRank = try c.decodeIfPresent(FlexibleInt.self, forKey: .frequencyRank)?.value
        strokeCount = try c.decodeIfPresent(FlexibleInt.self, forKey: .strokeCount)?.value
        onReadings = try c.decodeIfPresent([String].self, forKey: .onReadings) ?? []
        kunReadings = try c.decodeIfPresent([String].self, forKey: .kunReadings) ?? []
    }
}

/// One download of a card set, as stored on the device.
///
/// `datasetVersion` and `asOf` are kept because a cache without the age of its
/// contents cannot be reasoned about — 開発ガイド §7.
public struct CardCatalog<Card: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    public let datasetVersion: String
    public let asOf: String
    public let licenses: [CardLicense]
    public let cards: [Card]
    /// The validator to send back as `If-None-Match`. Empty when the server
    /// sent none, in which case the next fetch simply downloads again.
    public let entityTag: String
    public let fetchedAt: Date

    public init(
        datasetVersion: String,
        asOf: String,
        licenses: [CardLicense],
        cards: [Card],
        entityTag: String,
        fetchedAt: Date
    ) {
        self.datasetVersion = datasetVersion
        self.asOf = asOf
        self.licenses = licenses
        self.cards = cards
        self.entityTag = entityTag
        self.fetchedAt = fetchedAt
    }
}

extension CardLicense: Encodable {}

/// The two shapes the API returns. They differ: the word set lists `licenses`,
/// the kanji set a single `license`.
struct WordDatasetResponse: Decodable {
    let datasetVersion: String?
    let asOf: String?
    let licenses: [CardLicense]?
    let items: [WordCard]?
}

struct KanjiDatasetResponse: Decodable {
    let datasetVersion: String?
    let asOf: String?
    let license: CardLicense?
    let items: [KanjiCard]?
}
