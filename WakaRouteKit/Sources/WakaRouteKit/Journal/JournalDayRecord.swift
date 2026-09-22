import Foundation

/// One block of time in 一日の時間 — either one the server has, or one still
/// waiting in the outbox.
///
/// The two are drawn the same way on purpose: the student recorded both, and
/// which of them has finished uploading is not something they should have to
/// think about. What differs is that a queued block has no `entryId` yet, so it
/// cannot be deleted — and saying it is gone while it is still on its way would
/// not be true.
public struct DayLogRow: Identifiable, Sendable, Equatable {
    public let id: String
    public let category: JournalCategory
    public let durationMinutes: Int
    public let subject: String?
    public let content: String?
    public let isSent: Bool
    /// Present only once the server has it.
    public let entry: DayLogEntry?

    init(_ entry: DayLogEntry) {
        self.id = entry.entryId
        self.category = entry.category
        self.durationMinutes = entry.durationMinutes
        self.subject = entry.subject
        self.content = entry.content
        self.isSent = true
        self.entry = entry
    }

    init(queued entry: NewDayLogEntry) {
        self.id = entry.clientEntryId
        self.category = entry.category
        self.durationMinutes = entry.durationMinutes ?? 0
        self.subject = entry.subject
        self.content = entry.content
        self.isSent = false
        self.entry = nil
    }

    /// 数学・p.42 — whichever of the two the student filled in.
    public var detailLine: String? {
        let parts = [subject, content].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "・")
    }
}

public struct CategoryMinutes: Sendable, Equatable, Identifiable {
    public let category: JournalCategory
    public let minutes: Int

    public var id: String { category.rawValue }
}

/// A day as the student should see it: what the server holds, plus what this
/// device has recorded and not managed to send yet.
///
/// The outbox alone is not enough. Keeping a diary safe on disk while the
/// screen shows it vanishing is, from where the student is sitting, the same as
/// losing it — and this app's whole claim about offline is that **通信状況で学習
/// が消えません**. So the two sources are composed here, once, rather than in
/// each screen that needs them.
public struct JournalDayRecord: Sendable, Equatable {
    public let date: JournalDate
    public let diary: DiaryEntry?
    /// The diary on screen is one the server has not acknowledged.
    public let isDiaryUnsent: Bool
    public let rows: [DayLogRow]
    public let autoStudy: [AutoStudyEntry]
    public let practice: PracticeSummary?
    public let studySelfMinutes: Int
    public let studyAutoMinutes: Int
    public let minutesByCategory: [CategoryMinutes]
    /// Writes this device is still holding for this day.
    public let unsentCount: Int

    /// Whether there is anything at all to show.
    ///
    /// Distinguishes 「読み込めませんでした」 from 「その日は何もなかった」 — and
    /// lets a screen keep showing the student's own unsent work even when the
    /// read failed.
    public let hasContent: Bool

    public init(date: JournalDate, day: JournalDay?, unsent: [PendingJournalWrite]) {
        self.date = date

        let forThisDay = unsent.filter { $0.date == date }
        self.unsentCount = forThisDay.count

        // The last diary write wins: the endpoint is a full replace, so an
        // earlier queued save says nothing the later one does not.
        let queuedDiary = forThisDay.last { write in
            switch write.payload {
            case .diary, .deleteDiary: true
            case .entry: false
            }
        }

        switch queuedDiary?.payload {
        case let .diary(draft):
            self.diary = DiaryEntry(
                date: date,
                achievements: draft.achievements.isEmpty ? nil : draft.achievements,
                struggles: draft.struggles.isEmpty ? nil : draft.struggles,
                tomorrowPlan: draft.tomorrowPlan.isEmpty ? nil : draft.tomorrowPlan,
                focus: draft.focus,
                fatigue: draft.fatigue
            )
            self.isDiaryUnsent = true
        case .deleteDiary:
            self.diary = nil
            self.isDiaryUnsent = true
        default:
            self.diary = day?.diary
            self.isDiaryUnsent = false
        }

        let sent = (day?.entries ?? []).map(DayLogRow.init)

        // A block the server already accepted can still be sitting in the
        // outbox, if its response was lost on the way back. Matching on
        // `clientEntryId` — the same field the server deduplicates on — keeps
        // it from being drawn, and counted, twice.
        let alreadyLanded = Set((day?.entries ?? []).compactMap(\.clientEntryId))
        let queued = forThisDay.compactMap { write -> DayLogRow? in
            guard case let .entry(entry) = write.payload,
                  !alreadyLanded.contains(entry.clientEntryId)
            else { return nil }
            return DayLogRow(queued: entry)
        }

        self.rows = sent + queued
        self.autoStudy = day?.autoStudy ?? []
        self.practice = day?.practice

        // Queued minutes are counted. They are not an invented number: they are
        // the student's own entries, on the student's own device. Leaving them
        // out would put 「自主学習 60分」 in the list above a total of 0分.
        let queuedStudy = queued
            .filter { $0.category.countsAsStudy }
            .reduce(0) { $0 + $1.durationMinutes }

        self.studySelfMinutes = (day?.totals.studySelfMinutes ?? 0) + queuedStudy
        self.studyAutoMinutes = day?.totals.studyAutoMinutes ?? 0

        var minutes = day?.totals.minutesByCategory
            .reduce(into: [JournalCategory: Int]()) { $0[JournalCategory($1.key)] = $1.value } ?? [:]
        for row in queued {
            minutes[row.category, default: 0] += row.durationMinutes
        }
        self.minutesByCategory = minutes
            .map { CategoryMinutes(category: $0.key, minutes: $0.value) }
            .sorted { $0.minutes > $1.minutes }

        self.hasContent = day != nil || !forThisDay.isEmpty
    }

    /// See `headlineStudy(selfMinutes:autoMinutes:)` — the shared rule for the
    /// screens that can only show one number.
    public var headlineStudy: HeadlineStudy {
        WakaRouteKit.headlineStudy(selfMinutes: studySelfMinutes, autoMinutes: studyAutoMinutes)
    }

    public var loggedMinutes: Int { minutesByCategory.reduce(0) { $0 + $1.minutes } }

    public var remainingMinutes: Int { max(0, JournalLimits.minutesPerDay - loggedMinutes) }
}
