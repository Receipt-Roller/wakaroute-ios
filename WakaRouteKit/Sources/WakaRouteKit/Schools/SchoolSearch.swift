import Foundation

public enum SchoolOwnership: String, Decodable, Sendable, CaseIterable {
    case national, `public`, `private`
}

/// A school as returned by the WakaRoute catalogue.
///
/// `id` is the permanent key. School names are never used as identifiers —
/// they are not unique and they change.
public struct School: Decodable, Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let nameKana: String?
    public let prefectureCode: String?
    public let prefecture: String?
    public let address: String?
    public let ownership: SchoolOwnership?
    public let ownershipLabel: String?
    public let campusTypeLabel: String?
    public let officialUrl: String?
    public let latitude: Double?
    public let longitude: Double?
}

public struct SchoolSearchPage: Decodable, Sendable, Equatable {
    /// The date the catalogue itself is current as of — distinct from when we
    /// fetched it. Both are shown so a cached list is never mistaken for live.
    public let asOf: String?
    public let totalCount: Int
    public let page: Int
    public let pageSize: Int
    public let totalPages: Int
    public let items: [School]
}

public struct SchoolSearchQuery: Sendable, Equatable {
    public var keyword: String?
    public var prefectureCode: String?
    public var ownership: SchoolOwnership?
    public var page: Int
    public var pageSize: Int

    /// The API caps `pageSize` at 48 and rejects larger values.
    public static let maxPageSize = 48

    public init(
        keyword: String? = nil,
        prefectureCode: String? = nil,
        ownership: SchoolOwnership? = nil,
        page: Int = 1,
        pageSize: Int = 24
    ) {
        self.keyword = keyword
        self.prefectureCode = prefectureCode
        self.ownership = ownership
        self.page = max(1, page)
        self.pageSize = min(max(1, pageSize), Self.maxPageSize)
    }

    func queryItems() -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let keyword, !keyword.isEmpty { items.append(.init(name: "q", value: keyword)) }
        if let prefectureCode { items.append(.init(name: "prefecture", value: prefectureCode)) }
        if let ownership { items.append(.init(name: "ownership", value: ownership.rawValue)) }
        items.append(.init(name: "page", value: String(page)))
        items.append(.init(name: "pageSize", value: String(pageSize)))
        return items
    }
}

/// `GET /api/schools/{id}`.
///
/// Shapes follow `SchoolCatalogModels.cs` in wakaroute-web. Every collection
/// was empty on every school sampled on 2026-08-02 — the catalogue publishes
/// the structure before the data — so all of them decode to empty rather than
/// failing, and the UI treats absence as normal rather than as an error.
///
/// `profile` and `decisionGuide` are not modelled: they nest further types
/// (SchoolProgram, SchoolAccessGuide, SchoolVisitEvent…) that nothing in the
/// app needs yet.
public struct SchoolDetail: Decodable, Sendable, Equatable {
    public let school: School
    public let examSchedules: [SchoolExamSchedule]
    public let admissions: [SchoolAdmissionResult]
    public let deviationScores: [SchoolDeviationScore]

    private enum CodingKeys: String, CodingKey {
        case school, examSchedules, admissions, deviationScores
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        school = try container.decode(School.self, forKey: .school)
        examSchedules = try container.decodeIfPresent([SchoolExamSchedule].self, forKey: .examSchedules) ?? []
        admissions = try container.decodeIfPresent([SchoolAdmissionResult].self, forKey: .admissions) ?? []
        deviationScores = try container.decodeIfPresent([SchoolDeviationScore].self, forKey: .deviationScores) ?? []
    }

    /// The exam date to offer when this school is added as a 志望校.
    ///
    /// Picks the earliest sitting still in the future, so a catalogue carrying
    /// several years does not suggest a date that has already passed. Nil when
    /// nothing is published — the student sets it themselves.
    public func suggestedExamDate(after now: Date, calendar: Calendar = .current) -> Date? {
        let today = calendar.startOfDay(for: now)
        return examSchedules
            .flatMap(\.testDates)
            .compactMap { CatalogDate.parse($0, calendar: calendar) }
            .filter { $0 >= today }
            .min()
    }

    /// The most recent 偏差値, whichever provider published it.
    public var latestDeviationScore: SchoolDeviationScore? {
        deviationScores.max { $0.academicYear < $1.academicYear }
    }
}

/// Reads the school catalogue. This is the one WakaRoute endpoint that is live
/// today, and it needs no authentication.
public struct SchoolsClient: Sendable {
    private let http: HTTPClient
    private let environment: AppEnvironment

    public init(http: HTTPClient, environment: AppEnvironment) {
        self.http = http
        self.environment = environment
    }

    public func search(_ query: SchoolSearchQuery) async throws -> SchoolSearchPage {
        var components = URLComponents(
            url: environment.wakarouteBaseURL.appending(path: "/api/schools"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = query.queryItems()

        guard let url = components?.url else {
            throw APIError.unknown("Could not build the school search URL.")
        }

        return try await http.sendDecoding(
            HTTPRequest(method: .get, url: url, headers: ["Accept": "application/json"]),
            as: SchoolSearchPage.self
        )
    }

    /// One school by its permanent id.
    ///
    /// 志望校 are stored as an id plus a cached name, so this is how a saved
    /// goal is resolved back to full detail. A `404` means the id no longer
    /// exists in the catalogue — surfaced rather than swallowed, because a
    /// student's 志望校 quietly vanishing is worth telling them about.
    public func school(id: String) async throws -> School {
        try await schoolDetail(id: id).school
    }

    /// The full catalogue record: the school plus 入試日程, 入試結果 and 偏差値.
    public func schoolDetail(id: String) async throws -> SchoolDetail {
        let request = HTTPRequest(
            method: .get,
            url: environment.wakarouteBaseURL.appending(path: "/api/schools/\(id)"),
            headers: ["Accept": "application/json"]
        )
        return try await http.sendDecoding(request, as: SchoolDetail.self)
    }
}
