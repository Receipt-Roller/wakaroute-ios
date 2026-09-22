import Foundation
import Testing
@testable import WakaRouteKit

/// Copied verbatim from the API contract wiki
/// 「受験日記・生活学習時間ログ API 契約（MANABU2 /me/journal）」§4.3.
private let contractDay = """
{
  "date": "2026-09-21",
  "diary": { "date": "2026-09-21", "achievements": "二次関数の判別式がわかった", "struggles": null,
             "tomorrowPlan": "英語の長文 2 題", "focus": 4, "fatigue": 3,
             "updatedAt": "2026-09-21T13:04:55.0204684+09:00" },
  "entries": [
    { "entryId": "e-1", "clientEntryId": "ios-3F2A", "date": "2026-09-21", "category": "homework",
      "isStudy": true, "source": "self", "durationMinutes": 40, "startedAt": null, "endedAt": null,
      "subject": "数学", "content": "p.42", "createdAt": "2026-09-21T13:00:00+09:00",
      "updatedAt": "2026-09-21T13:00:00+09:00" }
  ],
  "autoStudy": [
    { "sessionId": "s-1", "source": "manabu2", "recordedBy": "timer", "kind": "practice", "subject": "数学",
      "courseId": null, "lessonId": null, "startedAt": "2026-09-21T10:00:00+09:00",
      "endedAt": "2026-09-21T10:25:00+09:00", "durationMinutes": 25 }
  ],
  "practice": { "sessions": 1, "answered": 8, "correct": 6, "minutes": 11 },
  "totals": { "minutesByCategory": { "homework": 40, "screen": 60 },
              "studySelfMinutes": 40, "studyAutoMinutes": 25 }
}
"""

/// §4.4.
private let contractSummary = """
[{ "date": "2026-09-15", "minutesByCategory": { "sleep": 420, "school": 400, "homework": 40 },
   "studySelfMinutes": 40, "studyAutoMinutes": 25, "hasDiary": true, "focus": 4, "fatigue": 3,
   "practice": { "sessions": 1, "answered": 8, "correct": 6, "minutes": 11 } }]
"""

private func decodeDay(_ json: String) throws -> JournalDay {
    try JSONDecoder.wakaRoute.decode(JournalDay.self, from: Data(json.utf8))
}

@Suite("Journal decoding")
struct JournalDecodingTests {

    @Test("Decodes the day payload from the contract")
    func decodesContractDay() throws {
        let day = try decodeDay(contractDay)

        #expect(day.date == JournalDate("2026-09-21"))
        #expect(day.diary?.achievements == "二次関数の判別式がわかった")
        #expect(day.diary?.struggles == nil)
        #expect(day.diary?.focus == 4)
        #expect(day.entries.count == 1)
        #expect(day.entries[0].category == .homework)
        #expect(day.entries[0].durationMinutes == 40)
        #expect(day.autoStudy.count == 1)
        #expect(day.autoStudy[0].recordedBy == "timer")
        #expect(day.practice?.correct == 6)
        #expect(!day.isEmpty)
    }

    /// The whole point of the two numbers. A student who runs the study timer
    /// for 25 minutes and also logs 40 minutes of 宿題 has somewhere between 40
    /// and 65 minutes of study, and neither the server nor this layer knows
    /// which — so neither of them decides.
    @Test("Self and auto study minutes stay apart")
    func studyMinutesAreNotSummed() throws {
        let totals = try decodeDay(contractDay).totals

        #expect(totals.studySelfMinutes == 40)
        #expect(totals.studyAutoMinutes == 25)
        #expect(totals.minutes(for: .homework) == 40)
        #expect(totals.minutes(for: .screen) == 60)
        #expect(totals.minutes(for: .club) == 0)
    }

    /// Practice minutes are an estimate the server deliberately leaves out of
    /// `studyAutoMinutes`. Adding them anywhere would inflate the day.
    @Test("Practice minutes are reported but never folded into a study total")
    func practiceMinutesStayOut() throws {
        let day = try decodeDay(contractDay)

        #expect(day.practice?.minutes == 11)
        #expect(day.totals.studyAutoMinutes == 25)
    }

    @Test("A day with nothing recorded decodes as empty rather than failing")
    func decodesEmptyDay() throws {
        let day = try decodeDay("""
        { "date": "2026-09-20", "diary": null, "entries": [], "autoStudy": [],
          "practice": null, "totals": { "minutesByCategory": {}, "studySelfMinutes": 0, "studyAutoMinutes": 0 } }
        """)

        #expect(day.isEmpty)
        #expect(day.totals.studySelfMinutes == 0)
    }

    /// A category added to the server after this build shipped must not take
    /// the student's whole day down with it.
    @Test("An unknown category decodes instead of failing the day")
    func unknownCategorySurvives() throws {
        let day = try decodeDay("""
        { "date": "2026-09-21", "diary": null,
          "entries": [{ "entryId": "e-9", "clientEntryId": null, "date": "2026-09-21",
                        "category": "volunteering", "isStudy": false, "source": "self",
                        "durationMinutes": 30, "startedAt": null, "endedAt": null,
                        "subject": null, "content": null, "createdAt": null, "updatedAt": null }],
          "autoStudy": [], "practice": null,
          "totals": { "minutesByCategory": { "volunteering": 30 }, "studySelfMinutes": 0, "studyAutoMinutes": 0 } }
        """)

        #expect(day.entries[0].category == JournalCategory("volunteering"))
        // Nothing is invented for it: it shows under its own code.
        #expect(day.entries[0].category.displayName == "volunteering")
        #expect(!day.entries[0].category.countsAsStudy)
    }

    @Test("Decodes the summary payload from the contract")
    func decodesContractSummary() throws {
        let days = try JSONDecoder.wakaRoute.decode(
            [JournalDaySummary].self, from: Data(contractSummary.utf8)
        )

        #expect(days.count == 1)
        #expect(days[0].date == JournalDate("2026-09-15"))
        #expect(days[0].hasDiary)
        #expect(days[0].minutes(for: .sleep) == 420)
        #expect(days[0].studySelfMinutes == 40)
    }

    /// The summary is what a student can choose to show a parent. If the words
    /// they wrote about their day were in it, that choice would be gone.
    @Test("The summary carries no diary text")
    func summaryHasNoDiaryText() throws {
        #expect(!contractSummary.contains("achievements"))
        #expect(!contractSummary.contains("struggles"))
        #expect(!contractSummary.contains("tomorrowPlan"))
    }

    /// Which categories count as study is stated in §3 and enforced by the
    /// server. Holding a second copy is only safe if it agrees.
    @Test("countsAsStudy matches the contract's three study categories")
    func studyCategoriesMatchContract() {
        let study = JournalCategory.known.filter(\.countsAsStudy)
        #expect(Set(study) == [.cramSchool, .selfStudy, .homework])
        #expect(JournalCategory.known.count == 9)
    }
}

@Suite("Journal dates")
struct JournalDateTests {

    /// Midnight in Tokyo is still the previous day in UTC. A diary written at
    /// 00:30 belongs to the day the student thinks it does.
    @Test("Just after midnight in Japan is the new day, not yesterday")
    func midnightIsJapanese() {
        let formatter = ISO8601DateFormatter()
        let justAfterMidnight = formatter.date(from: "2026-09-20T15:30:00Z")!  // 2026-09-21 00:30 JST

        #expect(JournalDate.from(justAfterMidnight) == JournalDate("2026-09-21"))
    }

    @Test("Rejects anything that is not yyyy-MM-dd")
    func rejectsBadText() {
        #expect(JournalDate("2026-9-21") == nil)
        #expect(JournalDate("2026/09/21") == nil)
        #expect(JournalDate("2026-09-21T00:00:00Z") == nil)
        #expect(JournalDate("") == nil)
        #expect(JournalDate("20xx-09-21") == nil)
    }

    @Test("Round-trips through JSON as a bare string")
    func encodesAsString() throws {
        let encoded = try JSONEncoder().encode(JournalDate("2026-09-21")!)
        #expect(String(decoding: encoded, as: UTF8.self) == "\"2026-09-21\"")
    }

    @Test("Counts days across a month boundary")
    func countsDays() {
        let end = JournalDate("2026-10-01")!
        #expect(end.daysSince(JournalDate("2026-09-21")!) == 10)
        #expect(end.adding(days: -10) == JournalDate("2026-09-21"))
    }

    /// The server accepts today back to 31 days. Checking here means the
    /// student is told before they type, not after they press save.
    @Test("The writable window is today back to 31 days")
    func writableWindow() {
        let today = JournalDate("2026-09-21")!

        #expect(today.isWritable(on: today))
        #expect(today.adding(days: -31).isWritable(on: today))
        #expect(!today.adding(days: -32).isWritable(on: today))
        #expect(!today.adding(days: 1).isWritable(on: today), "Tomorrow has not happened yet.")
    }
}

@Suite("Diary drafts")
struct DiaryDraftTests {

    /// `PUT` replaces the diary outright. A form built from nothing rather than
    /// from the current value would clear the fields it does not show.
    @Test("A draft made from an existing diary carries every field back")
    func draftRoundTrips() throws {
        let diary = try decodeDay(contractDay).diary
        let draft = DiaryDraft(diary)

        #expect(draft.achievements == "二次関数の判別式がわかった")
        #expect(draft.struggles == "")
        #expect(draft.tomorrowPlan == "英語の長文 2 題")
        #expect(draft.focus == 4)
        #expect(draft.fatigue == 3)

        let object = try JSONSerialization.jsonObject(
            with: try JSONEncoder.wakaRoute.encode(draft)
        ) as? [String: Any]

        // Every key is present, including the ones being cleared — that is what
        // a full replace needs.
        #expect(object?.keys.count == 5)
        #expect(object?["achievements"] as? String == "二次関数の判別式がわかった")
        #expect(object?["struggles"] is NSNull, "An empty field clears, rather than storing \"\".")
    }

    @Test("An all-empty draft is recognised so it can be deleted instead of sent")
    func emptyDraftIsEmpty() {
        #expect(DiaryDraft().isEmpty)
        #expect(DiaryDraft(achievements: "   \n ").isEmpty, "Whitespace is not a diary.")
        #expect(!DiaryDraft(achievements: "やった").isEmpty)
        #expect(!DiaryDraft(focus: 3).isEmpty, "A mood on its own is still a record.")
    }
}

// MARK: - Client

/// Records what the client sent and replies with canned bodies.
private final class JournalStubClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [HTTPRequest] = []
    var status = 200
    var body = "{}"

    private static let registration = """
    { "deviceSecret": "mnbd_test", "isNewAccount": true,
      "auth": { "accessToken": "access", "expiresAt": "2033-01-01T00:00:00Z",
                "refreshToken": "refresh", "scopes": ["write:progress"],
                "user": { "id": "u-1", "email": "", "displayName": "" } } }
    """

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let path = request.url.path()
        if path.hasSuffix("/devices/register") || path.hasSuffix("/auth/refresh") || path.hasSuffix("/devices/token") {
            return HTTPResponse(status: 200, body: Data(Self.registration.utf8))
        }

        lock.withLock { requests.append(request) }
        return HTTPResponse(status: status, body: Data(body.utf8))
    }
}

private func makeClient(_ http: JournalStubClient) -> JournalClient {
    let store = InMemorySecretStore()
    let auth = AuthSession(
        client: DeviceAuthClient(http: http, environment: .production),
        store: store,
        deviceIdProvider: StoredDeviceIdProvider(store: store)
    )
    return JournalClient(
        http: AuthenticatedHTTPClient(underlying: http, session: auth),
        environment: .production
    )
}

@Suite("Journal client")
struct JournalClientTests {

    @Test("Reads a day from the date-keyed path")
    func readsADay() async throws {
        let http = JournalStubClient()
        http.body = contractDay

        let day = try await makeClient(http).day(JournalDate("2026-09-21")!)

        #expect(day.entries.count == 1)
        #expect(http.requests.last?.url.path().hasSuffix("/me/journal/2026-09-21") == true)
        #expect(http.requests.last?.method == .get)
    }

    @Test("A range is sent as from and to")
    func sendsRange() async throws {
        let http = JournalStubClient()
        http.body = "[]"

        _ = try await makeClient(http).days(
            from: JournalDate("2026-09-15")!, to: JournalDate("2026-09-21")!
        )

        let query = http.requests.last?.url.query()
        #expect(query?.contains("from=2026-09-15") == true)
        #expect(query?.contains("to=2026-09-21") == true)
    }

    /// A block posted over a dying connection can succeed on the server and
    /// still look like a failure here. Re-sending the same entry must send the
    /// same id, or the student's 40 minutes are logged twice.
    @Test("A retried entry carries the same clientEntryId")
    func retryKeepsTheSameId() async throws {
        let http = JournalStubClient()
        http.body = """
        { "entryId": "e-1", "clientEntryId": "ios-3F2A", "date": "2026-09-21", "category": "homework",
          "isStudy": true, "source": "self", "durationMinutes": 40, "startedAt": null, "endedAt": null,
          "subject": null, "content": null, "createdAt": null, "updatedAt": null }
        """

        let entry = NewDayLogEntry(category: .homework, durationMinutes: 40)
        let client = makeClient(http)
        let today = JournalDate.today()

        _ = try await client.addEntry(entry, on: today)
        _ = try await client.addEntry(entry, on: today)

        let ids = try http.requests.map { request -> String in
            let object = try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any]
            return object?["clientEntryId"] as? String ?? ""
        }
        #expect(ids.count == 2)
        #expect(ids[0] == ids[1])
        #expect(ids[0].hasPrefix("ios-"))
    }

    /// The student finds out before they type, not after they press save.
    @Test("A date outside the writable window is refused without a request")
    func refusesUnwritableDates() async throws {
        let http = JournalStubClient()
        let client = makeClient(http)
        let tooOld = JournalDate.today().adding(days: -40)

        await #expect(throws: APIError.self) {
            try await client.saveDiary(DiaryDraft(achievements: "やった"), on: tooOld)
        }
        #expect(http.requests.isEmpty, "Nothing should reach the network.")
    }

    /// Clearing every field is a delete. Sending it as a save is a 400 and the
    /// diary stays where it was.
    @Test("An emptied diary is deleted rather than saved")
    func emptyDiaryDeletes() async throws {
        let http = JournalStubClient()
        http.status = 204
        http.body = ""

        let saved = try await makeClient(http).saveDiary(DiaryDraft(), on: JournalDate.today())

        #expect(saved == nil)
        #expect(http.requests.last?.method == .delete)
        #expect(http.requests.last?.url.path().hasSuffix("/diary") == true)
    }

    @Test("A 204 delete does not fail on the empty body")
    func deleteHandlesEmptyBody() async throws {
        let http = JournalStubClient()
        http.status = 204
        http.body = ""

        try await makeClient(http).deleteEntry("e-1")

        #expect(http.requests.last?.url.path().hasSuffix("/me/journal/entries/e-1") == true)
    }

    @Test("Server refusals arrive as codes the screen can act on")
    func mapsRefusals() async throws {
        let http = JournalStubClient()
        http.status = 400
        http.body = #"{ "title": "Bad Request", "status": 400, "detail": "…", "code": "day_full" }"#

        do {
            _ = try await makeClient(http).addEntry(
                NewDayLogEntry(category: .sleep, durationMinutes: 600), on: JournalDate.today()
            )
            Issue.record("Expected the server's refusal to be thrown")
        } catch {
            #expect(JournalRefusal(error) == .dayFull)
        }
    }
}

@Suite("Journal outbox")
struct JournalOutboxTests {

    private func makeOutbox(_ http: JournalStubClient, store: any JournalOutboxStore = InMemoryJournalOutboxStore())
        -> JournalOutbox
    {
        JournalOutbox(store: store, client: makeClient(http))
    }

    /// The diary endpoint is a full replace. Two queued saves for one day are
    /// not two edits — the newer one already says everything the older one did,
    /// and sending the older one first would briefly put the student's earlier
    /// text back.
    @Test("A second diary save for the same day replaces the queued one")
    func diaryWritesCollapse() async throws {
        let outbox = makeOutbox(JournalStubClient())
        let today = JournalDate.today()

        await outbox.queue(diary: DiaryDraft(achievements: "はじめに書いたこと"), on: today)
        await outbox.queue(diary: DiaryDraft(achievements: "書き直したこと"), on: today)

        let pending = await outbox.pending()
        #expect(pending.count == 1)
        #expect(pending[0].payload == .diary(DiaryDraft(achievements: "書き直したこと")))
    }

    @Test("Diary saves for different days both wait their turn")
    func differentDaysAreKept() async throws {
        let outbox = makeOutbox(JournalStubClient())
        let today = JournalDate.today()

        await outbox.queue(diary: DiaryDraft(achievements: "きょう"), on: today)
        await outbox.queue(diary: DiaryDraft(achievements: "きのう"), on: today.adding(days: -1))

        #expect(await outbox.pending().count == 2)
    }

    /// Two 30-minute blocks are two blocks. Only the diary collapses.
    @Test("Time blocks accumulate rather than replacing one another")
    func entriesAccumulate() async throws {
        let outbox = makeOutbox(JournalStubClient())
        let today = JournalDate.today()

        await outbox.queue(entry: NewDayLogEntry(category: .selfStudy, durationMinutes: 30), on: today)
        await outbox.queue(entry: NewDayLogEntry(category: .selfStudy, durationMinutes: 30), on: today)

        #expect(await outbox.pendingCount(for: today) == 2)
    }

    @Test("A successful run empties the queue")
    func runSendsEverything() async throws {
        let http = JournalStubClient()
        http.status = 201
        http.body = """
        { "entryId": "e-1", "clientEntryId": "ios-1", "date": "\(JournalDate.today().text)", "category": "homework",
          "isStudy": true, "source": "self", "durationMinutes": 40, "startedAt": null, "endedAt": null,
          "subject": null, "content": null, "createdAt": null, "updatedAt": null }
        """
        let outbox = makeOutbox(http)

        await outbox.queue(entry: NewDayLogEntry(category: .homework, durationMinutes: 40), on: JournalDate.today())
        let outcome = await outbox.run()

        #expect(outcome == .sent(count: 1))
        #expect(await outbox.pending().isEmpty)
    }

    /// A 503 is about this moment, not this write. It stays queued.
    @Test("A transient failure keeps the write for next time")
    func transientFailureKeepsTheWrite() async throws {
        let http = JournalStubClient()
        http.status = 503
        let outbox = makeOutbox(http)

        await outbox.queue(diary: DiaryDraft(achievements: "書いた"), on: JournalDate.today())
        let outcome = await outbox.run()

        #expect(outcome == .failed)
        #expect(await outbox.pending().count == 1, "The diary must still be there to send.")
    }

    /// A day that scrolled past the 31-day window will be refused every time.
    /// Left at the head of the queue it would block everything behind it.
    @Test("A permanently refused write is set aside, not retried forever")
    func permanentFailureIsSetAside() async throws {
        let http = JournalStubClient()
        http.status = 400
        http.body = #"{ "status": 400, "code": "date_not_writable" }"#
        let outbox = makeOutbox(http)

        await outbox.queue(diary: DiaryDraft(achievements: "ふるい日"), on: JournalDate.today())
        _ = await outbox.run()

        #expect(await outbox.pending().isEmpty)
        #expect(await outbox.run() == .nothingToDo, "It must not be attempted again.")
    }

    /// The whole point of writing to disk: the app was killed on the train.
    @Test("The queue survives being reloaded from the store")
    func queueSurvivesRelaunch() async throws {
        let store = InMemoryJournalOutboxStore()
        let today = JournalDate.today()

        let first = makeOutbox(JournalStubClient(), store: store)
        await first.queue(diary: DiaryDraft(achievements: "電車で書いた", focus: 4), on: today)

        let second = makeOutbox(JournalStubClient(), store: store)
        let pending = await second.pending()

        #expect(pending.count == 1)
        #expect(pending[0].date == today)
        #expect(pending[0].payload == .diary(DiaryDraft(achievements: "電車で書いた", focus: 4)))
    }
}

@Suite("Which study number a screen shows")
struct HeadlineStudyTests {

    /// The timer only sees study done with the app open. 塾, a problem book and
    /// homework at the kitchen table are invisible to it, and for a student
    /// sitting entrance exams that is most of the studying.
    @Test("The student's own record is the one shown")
    func selfWins() {
        let totals = DayTotals(minutesByCategory: [:], studySelfMinutes: 40, studyAutoMinutes: 25)

        #expect(totals.headlineStudy == HeadlineStudy(minutes: 40, source: .learner))
    }

    /// `self` is claimed, `auto` is measured. A day with no entries but a
    /// 90-minute timer session is a day they studied for 90 minutes — printing
    /// 「0分」 at that student would be worse than either number alone.
    @Test("A day logged by nobody but the timer shows the timer")
    func autoFillsTheGap() {
        let totals = DayTotals(minutesByCategory: [:], studySelfMinutes: 0, studyAutoMinutes: 90)

        #expect(totals.headlineStudy == HeadlineStudy(minutes: 90, source: .app))
    }

    @Test("A day with nothing at all is zero, from the student's side")
    func emptyDay() {
        #expect(DayTotals.empty.headlineStudy == HeadlineStudy(minutes: 0, source: .learner))
    }

    /// Whatever else changes, these two never become one number.
    @Test("The headline is never the sum")
    func neverTheSum() {
        let totals = DayTotals(minutesByCategory: [:], studySelfMinutes: 40, studyAutoMinutes: 25)

        #expect(totals.headlineStudy.minutes != 65)
    }

    @Test("The weekly summary answers the same way as the day")
    func summaryAgreesWithTheDay() throws {
        let days = try JSONDecoder.wakaRoute.decode(
            [JournalDaySummary].self, from: Data(contractSummary.utf8)
        )

        #expect(days[0].headlineStudy == HeadlineStudy(minutes: 40, source: .learner))
    }
}

/// What the student sees when the network is not cooperating.
///
/// The outbox keeps their work; this is the half that shows it to them. An
/// outbox that holds a diary safely while the screen shows it disappearing has,
/// from where the student is sitting, lost it.
@Suite("A day, server plus outbox")
struct JournalDayRecordTests {

    private let today = JournalDate("2026-09-21")!

    private func queuedEntry(
        _ category: JournalCategory, _ minutes: Int, id: String = "ios-1", on date: JournalDate? = nil
    ) -> PendingJournalWrite {
        PendingJournalWrite(
            date: date ?? JournalDate("2026-09-21")!,
            payload: .entry(NewDayLogEntry(clientEntryId: id, category: category, durationMinutes: minutes))
        )
    }

    @Test("With nothing queued, the day is exactly what the server sent")
    func passesTheServerThrough() throws {
        let day = try decodeDay(contractDay)
        let record = JournalDayRecord(date: today, day: day, unsent: [])

        #expect(record.diary?.achievements == "二次関数の判別式がわかった")
        #expect(!record.isDiaryUnsent)
        #expect(record.rows.count == 1)
        #expect(record.rows.filter(\.isSent).count == record.rows.count)
        #expect(record.studySelfMinutes == 40)
        #expect(record.unsentCount == 0)
    }

    /// The student typed it on a train. It is on screen because they wrote it.
    @Test("A queued diary is shown, and marked as not yet sent")
    func queuedDiaryIsShown() {
        let record = JournalDayRecord(
            date: today,
            day: nil,
            unsent: [PendingJournalWrite(
                date: today,
                payload: .diary(DiaryDraft(achievements: "電車で書いた", focus: 4))
            )]
        )

        #expect(record.diary?.achievements == "電車で書いた")
        #expect(record.diary?.focus == 4)
        #expect(record.isDiaryUnsent)
        #expect(record.hasContent, "There is something to show even though the read failed.")
    }

    /// A queued edit is newer than what the server has, and replaces it — the
    /// endpoint is a full replace, so this is what the diary will be.
    @Test("A queued diary wins over the server's older copy")
    func queuedDiaryBeatsTheServer() throws {
        let record = JournalDayRecord(
            date: today,
            day: try decodeDay(contractDay),
            unsent: [PendingJournalWrite(date: today, payload: .diary(DiaryDraft(achievements: "書き直した")))]
        )

        #expect(record.diary?.achievements == "書き直した")
        #expect(record.diary?.tomorrowPlan == nil, "A full replace clears what it does not carry.")
        #expect(record.isDiaryUnsent)
    }

    @Test("A queued deletion empties the diary rather than showing the old one")
    func queuedDeletionHides() throws {
        let record = JournalDayRecord(
            date: today,
            day: try decodeDay(contractDay),
            unsent: [PendingJournalWrite(date: today, payload: .deleteDiary)]
        )

        #expect(record.diary == nil)
        #expect(record.isDiaryUnsent)
    }

    /// 「自主学習 60分」 in the list above a total of 0分 is not a screen anyone
    /// should have to read.
    @Test("A queued block appears in the list and in the day's totals")
    func queuedBlockCounts() {
        let record = JournalDayRecord(date: today, day: nil, unsent: [queuedEntry(.selfStudy, 60)])

        #expect(record.rows.count == 1)
        #expect(record.rows[0].isSent == false)
        #expect(record.rows[0].entry == nil, "Nothing to delete until the server has it.")
        #expect(record.studySelfMinutes == 60)
        #expect(record.minutesByCategory == [CategoryMinutes(category: .selfStudy, minutes: 60)])
    }

    @Test("A queued non-study block is counted in the day, but not as study")
    func queuedNonStudyIsNotStudy() {
        let record = JournalDayRecord(date: today, day: nil, unsent: [queuedEntry(.club, 120)])

        #expect(record.loggedMinutes == 120)
        #expect(record.studySelfMinutes == 0)
    }

    /// The server accepted it but the reply never arrived, so it is in both
    /// places. Drawing it twice would tell the student they studied twice as
    /// long as they did.
    @Test("A block that landed but is still queued is not counted twice")
    func noDoubleCounting() throws {
        let day = try decodeDay(contractDay)
        let alreadyLanded = try #require(day.entries.first?.clientEntryId)

        let record = JournalDayRecord(
            date: today,
            day: day,
            unsent: [queuedEntry(.homework, 40, id: alreadyLanded)]
        )

        #expect(record.rows.count == 1)
        #expect(record.rows[0].isSent, "The server's copy is the one kept.")
        #expect(record.studySelfMinutes == 40, "Not 80.")
    }

    @Test("Writes queued for another day do not appear on this one")
    func otherDaysAreLeftAlone() {
        let record = JournalDayRecord(
            date: today,
            day: nil,
            unsent: [queuedEntry(.selfStudy, 60, on: today.adding(days: -1))]
        )

        #expect(record.rows.isEmpty)
        #expect(record.unsentCount == 0)
        #expect(!record.hasContent)
    }

    /// The distinction the screen needs: a Tuesday with nothing on it is not a
    /// Tuesday that failed to load.
    @Test("An empty day differs from a day that could not be read")
    func emptyVersusUnread() throws {
        let emptyDay = try decodeDay("""
        { "date": "2026-09-21", "diary": null, "entries": [], "autoStudy": [], "practice": null,
          "totals": { "minutesByCategory": {}, "studySelfMinutes": 0, "studyAutoMinutes": 0 } }
        """)

        #expect(JournalDayRecord(date: today, day: emptyDay, unsent: []).hasContent)
        #expect(!JournalDayRecord(date: today, day: nil, unsent: []).hasContent)
    }

    /// The whole reason both numbers exist.
    @Test("Queued study joins the student's own total, never the timer's")
    func queuedStudyJoinsSelfOnly() throws {
        let record = JournalDayRecord(
            date: today,
            day: try decodeDay(contractDay),
            unsent: [queuedEntry(.selfStudy, 30, id: "ios-new")]
        )

        #expect(record.studySelfMinutes == 70, "40 on the server, 30 still here.")
        #expect(record.studyAutoMinutes == 25, "Untouched.")
        #expect(record.headlineStudy == HeadlineStudy(minutes: 70, source: .learner))
    }

    @Test("The day's remaining capacity accounts for what is still queued")
    func remainingCountsTheQueue() {
        let record = JournalDayRecord(date: today, day: nil, unsent: [queuedEntry(.sleep, 480)])

        #expect(record.remainingMinutes == JournalLimits.minutesPerDay - 480)
    }
}
