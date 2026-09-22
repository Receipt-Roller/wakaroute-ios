import Foundation

/// The edits `PUT /entries/{entryId}` accepts.
///
/// The day is not one of them. Moving a block to another day is a delete and an
/// add, which is also what it means: the minutes left one day and joined
/// another, and both days' totals have to be re-checked against the 24-hour
/// limit.
public struct DayLogEdit: Sendable, Equatable, Encodable {
    public var category: JournalCategory
    public var durationMinutes: Int?
    public var startedAt: Date?
    public var endedAt: Date?
    public var subject: String?
    public var content: String?

    public init(
        category: JournalCategory,
        durationMinutes: Int? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        subject: String? = nil,
        content: String? = nil
    ) {
        self.category = category
        self.durationMinutes = durationMinutes
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.subject = subject
        self.content = content
    }

    public init(_ entry: DayLogEntry) {
        self.init(
            category: entry.category,
            durationMinutes: entry.durationMinutes,
            startedAt: entry.startedAt,
            endedAt: entry.endedAt,
            subject: entry.subject,
            content: entry.content
        )
    }
}

/// Why a write was refused, in terms a screen can act on.
///
/// The server's `detail` is prose and the guide says its wording can change, so
/// nothing is shown to a student from it. These come from `code`.
public enum JournalRefusal: Sendable, Equatable {
    /// In the future, or more than 31 days ago.
    case dateNotWritable
    /// The day already holds 24 hours of self-logged time.
    case dayFull
    /// The day already holds 50 blocks.
    case tooManyEntries
    /// The request was malformed — a category this build does not know about,
    /// a duration out of range, text over the limit.
    case invalidRequest
    /// Called with an API key instead of the learner's own token. A bug, not
    /// something the student can fix.
    case learnerTokenRequired

    public init?(_ error: any Error) {
        switch (error as? APIError)?.code {
        case "date_not_writable": self = .dateNotWritable
        case "day_full": self = .dayFull
        case "too_many_entries": self = .tooManyEntries
        case "invalid_request": self = .invalidRequest
        case "user_credential_required": self = .learnerTokenRequired
        default: return nil
        }
    }
}

/// 受験日記 and the daily time log, as MANABU2 stores them.
///
/// The app keeps none of this. There is no local copy of a diary to merge, no
/// second version of the day's totals to disagree with the server's — the one
/// thing held on the device is a queue of blocks that have not been uploaded
/// yet, each carrying the `clientEntryId` it will keep forever.
public struct JournalClient: Sendable {
    private let http: any HTTPClient
    private let environment: AppEnvironment

    public init(http: AuthenticatedHTTPClient, environment: AppEnvironment) {
        self.http = http
        self.environment = environment
    }

    // MARK: Reading

    /// The category list and the day's limits. Static — worth fetching once.
    public func categories() async throws -> [JournalCategoryInfo] {
        try await get(path: "/categories", as: [JournalCategoryInfo].self)
    }

    /// One day, whole. This is the entire 「今日」 screen in one request.
    public func day(_ date: JournalDate) async throws -> JournalDay {
        try await get(path: "/\(date.text)", as: JournalDay.self)
    }

    /// Days in a range, newest first.
    ///
    /// Days with nothing recorded come back as empty elements rather than being
    /// left out, so a week is always seven entries and the app never fabricates
    /// the gaps.
    public func days(from: JournalDate, to: JournalDate) async throws -> [JournalDay] {
        try await get(
            path: "",
            query: [URLQueryItem(name: "from", value: from.text), URLQueryItem(name: "to", value: to.text)],
            as: [JournalDay].self
        )
    }

    /// Daily totals, oldest first, **without the diary's words**.
    ///
    /// This is what a screen the student chooses to show a parent is built
    /// from. What they wrote about their day stays theirs.
    public func summary(from: JournalDate, to: JournalDate) async throws -> [JournalDaySummary] {
        try await get(
            path: "/summary",
            query: [URLQueryItem(name: "from", value: from.text), URLQueryItem(name: "to", value: to.text)],
            as: [JournalDaySummary].self
        )
    }

    // MARK: The diary

    /// Replaces the day's diary.
    ///
    /// Every field is sent, every time — see `DiaryDraft`. An empty draft is a
    /// delete, because the server answers 400 to a diary with nothing in it and
    /// "I cleared it all" is plainly a delete anyway.
    @discardableResult
    public func saveDiary(_ draft: DiaryDraft, on date: JournalDate) async throws -> DiaryEntry? {
        guard !draft.isEmpty else {
            try await deleteDiary(on: date)
            return nil
        }

        try requireWritable(date)

        return try await send(
            method: .put,
            path: "/\(date.text)/diary",
            body: try JSONEncoder.wakaRoute.encode(draft),
            as: DiaryEntry.self
        )
    }

    public func deleteDiary(on date: JournalDate) async throws {
        try requireWritable(date)
        try await sendIgnoringBody(method: .delete, path: "/\(date.text)/diary")
    }

    // MARK: Time blocks

    /// Adds a block of time to a day.
    ///
    /// Safe to call again with the same `NewDayLogEntry` after a timeout: the
    /// server matches on `clientEntryId` and returns the row it already has.
    @discardableResult
    public func addEntry(_ entry: NewDayLogEntry, on date: JournalDate) async throws -> DayLogEntry {
        try requireWritable(date)

        return try await send(
            method: .post,
            path: "/\(date.text)/entries",
            body: try JSONEncoder.wakaRoute.encode(entry),
            as: DayLogEntry.self
        )
    }

    @discardableResult
    public func updateEntry(_ entryId: String, to edit: DayLogEdit) async throws -> DayLogEntry {
        try await send(
            method: .put,
            path: "/entries/\(entryId)",
            body: try JSONEncoder.wakaRoute.encode(edit),
            as: DayLogEntry.self
        )
    }

    public func deleteEntry(_ entryId: String) async throws {
        try await sendIgnoringBody(method: .delete, path: "/entries/\(entryId)")
    }

    // MARK: - Plumbing

    /// Refuses a write the server is certain to refuse.
    ///
    /// Not an optimisation. The student finds out before they type a diary
    /// entry, rather than after — a 400 arriving on save is a lost paragraph.
    private func requireWritable(_ date: JournalDate) throws {
        guard date.isWritable() else {
            throw APIError.http(
                status: 400,
                problem: ProblemDetails(title: nil, status: 400, detail: nil, code: "date_not_writable")
            )
        }
    }

    private func url(path: String, query: [URLQueryItem] = []) throws -> URL {
        let base = environment.manabu2BaseURL.appending(path: "/api/v1/me/journal" + path)
        guard !query.isEmpty else { return base }

        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.queryItems = query
        guard let url = components?.url else {
            throw APIError.unknown("Could not build the journal URL.")
        }
        return url
    }

    private func get<T: Decodable>(path: String, query: [URLQueryItem] = [], as type: T.Type) async throws -> T {
        try await http.sendDecoding(
            HTTPRequest(method: .get, url: try url(path: path, query: query), headers: ["Accept": "application/json"]),
            as: T.self
        )
    }

    private func send<T: Decodable>(method: HTTPRequest.Method, path: String, body: Data, as type: T.Type) async throws -> T {
        try await http.sendDecoding(
            HTTPRequest(
                method: method,
                url: try url(path: path),
                headers: ["Content-Type": "application/json", "Accept": "application/json"],
                body: body
            ),
            as: T.self
        )
    }

    /// For the 204s. `sendDecoding` cannot be used — there is no body to decode.
    private func sendIgnoringBody(method: HTTPRequest.Method, path: String) async throws {
        let response = try await http.send(
            HTTPRequest(method: method, url: try url(path: path), headers: ["Accept": "application/json"])
        )

        guard (200..<300).contains(response.status) else {
            let problem = try? JSONDecoder().decode(ProblemDetails.self, from: response.body)
            throw APIError.http(status: response.status, problem: problem)
        }
    }
}
