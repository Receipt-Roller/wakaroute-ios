import Foundation

// MARK: - Categories

/// One of the fixed kinds of time block a student can log.
///
/// A `RawRepresentable` struct rather than an enum, matching `SubjectId`: the
/// server owns this list and serves it from `/categories`, so a category added
/// after this build shipped must arrive as data, not as a decoding failure that
/// blanks out the student's day.
public struct JournalCategory: Hashable, Sendable, Codable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public static let school = JournalCategory("school")
    public static let club = JournalCategory("club")
    public static let cramSchool = JournalCategory("cram_school")
    public static let selfStudy = JournalCategory("self_study")
    public static let homework = JournalCategory("homework")
    public static let screen = JournalCategory("screen")
    public static let sleep = JournalCategory("sleep")
    public static let free = JournalCategory("free")
    public static let other = JournalCategory("other")

    /// In the order they are offered on the 記録 screen.
    public static let known: [JournalCategory] = [
        .selfStudy, .homework, .cramSchool, .school, .club, .screen, .sleep, .free, .other
    ]

    /// Which categories the server counts toward `studySelfMinutes`.
    ///
    /// Held here as well as on the server so the app can show the running total
    /// while the student is still typing, and so an entry queued offline is
    /// grouped the same way before it is ever uploaded. `JournalCategory.known`
    /// is the source of truth for display; this is the source of truth for
    /// arithmetic, and the two are checked against the server's own
    /// `isStudy` flag in `DayLogEntry`.
    public var countsAsStudy: Bool {
        self == .cramSchool || self == .selfStudy || self == .homework
    }

    public var displayName: String {
        switch self {
        case .school: "学校"
        case .club: "部活"
        case .cramSchool: "塾・習い事"
        case .selfStudy: "自主学習"
        case .homework: "宿題"
        case .screen: "ゲーム・動画・SNS"
        case .sleep: "睡眠"
        case .free: "自由時間"
        case .other: "その他"
        default: rawValue
        }
    }
}

/// What `GET /categories` returns: the list, plus the day's limits.
public struct JournalCategoryInfo: Sendable, Codable, Equatable, Identifiable {
    public let code: JournalCategory
    public let name: String
    public let isStudy: Bool

    public var id: String { code.rawValue }
}

/// The server's limits on a single day.
public enum JournalLimits {
    /// A day holds 24 hours and no more (`day_full`).
    public static let minutesPerDay = 1440
    /// `too_many_entries`.
    public static let entriesPerDay = 50
    public static let diaryTextLength = 1000
    public static let subjectLength = 60
    public static let contentLength = 200
    /// The widest range `GET /?from=&to=` accepts.
    public static let rangeDays = 100
}

// MARK: - Diary

/// 受験日記 — what the student wrote about a day.
public struct DiaryEntry: Sendable, Codable, Equatable {
    public let date: JournalDate
    /// できたこと
    public let achievements: String?
    /// 困ったこと
    public let struggles: String?
    /// 明日やること
    public let tomorrowPlan: String?
    /// 集中度 1–5
    public let focus: Int?
    /// 疲労 1–5
    public let fatigue: Int?
    public let updatedAt: Date?

    public init(
        date: JournalDate,
        achievements: String? = nil,
        struggles: String? = nil,
        tomorrowPlan: String? = nil,
        focus: Int? = nil,
        fatigue: Int? = nil,
        updatedAt: Date? = nil
    ) {
        self.date = date
        self.achievements = achievements
        self.struggles = struggles
        self.tomorrowPlan = tomorrowPlan
        self.focus = focus
        self.fatigue = fatigue
        self.updatedAt = updatedAt
    }
}

/// What the edit form sends back.
///
/// `PUT /{date}/diary` **replaces** the whole diary — anything left out is
/// cleared. So this carries every field, always, and the form has to be opened
/// from the current value rather than built from nothing. Writing only
/// 明日やること would otherwise silently erase what the student wrote this
/// morning about できたこと.
public struct DiaryDraft: Sendable, Equatable, Codable {
    public var achievements: String
    public var struggles: String
    public var tomorrowPlan: String
    public var focus: Int?
    public var fatigue: Int?

    public init(
        achievements: String = "",
        struggles: String = "",
        tomorrowPlan: String = "",
        focus: Int? = nil,
        fatigue: Int? = nil
    ) {
        self.achievements = achievements
        self.struggles = struggles
        self.tomorrowPlan = tomorrowPlan
        self.focus = focus
        self.fatigue = fatigue
    }

    public init(_ diary: DiaryEntry?) {
        self.init(
            achievements: diary?.achievements ?? "",
            struggles: diary?.struggles ?? "",
            tomorrowPlan: diary?.tomorrowPlan ?? "",
            focus: diary?.focus,
            fatigue: diary?.fatigue
        )
    }

    /// An entirely empty diary is a 400, not a save.
    ///
    /// The caller deletes instead — which is what the student meant by clearing
    /// every field.
    public var isEmpty: Bool {
        [achievements, struggles, tomorrowPlan].allSatisfy(\.isBlank)
            && focus == nil && fatigue == nil
    }

    private enum Key: String, CodingKey { case achievements, struggles, tomorrowPlan, focus, fatigue }

    /// Blank text is sent as null so the server stores nothing rather than an
    /// empty string, which would make `hasDiary` true for a diary with no words
    /// in it.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(achievements.trimmedOrNil, forKey: .achievements)
        try container.encode(struggles.trimmedOrNil, forKey: .struggles)
        try container.encode(tomorrowPlan.trimmedOrNil, forKey: .tomorrowPlan)
        try container.encode(focus, forKey: .focus)
        try container.encode(fatigue, forKey: .fatigue)
    }

    /// Read back from the outbox, where a draft waits out a lost connection.
    /// The nulls it was written with come back as the empty fields they were.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        achievements = try container.decodeIfPresent(String.self, forKey: .achievements) ?? ""
        struggles = try container.decodeIfPresent(String.self, forKey: .struggles) ?? ""
        tomorrowPlan = try container.decodeIfPresent(String.self, forKey: .tomorrowPlan) ?? ""
        focus = try container.decodeIfPresent(Int.self, forKey: .focus)
        fatigue = try container.decodeIfPresent(Int.self, forKey: .fatigue)
    }
}

private extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var trimmedOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Time blocks

/// A block of time the student logged themselves (`source: self`).
public struct DayLogEntry: Sendable, Codable, Equatable, Identifiable {
    public let entryId: String
    public let clientEntryId: String?
    public let date: JournalDate
    public let category: JournalCategory
    public let isStudy: Bool
    public let durationMinutes: Int
    public let startedAt: Date?
    public let endedAt: Date?
    public let subject: String?
    public let content: String?
    public let createdAt: Date?
    public let updatedAt: Date?

    public var id: String { entryId }
}

/// A new block, on its way to `POST /{date}/entries`.
///
/// `clientEntryId` is generated here and never regenerated on retry. A block
/// posted over a dying connection can succeed on the server and still look like
/// a failure on the phone; sending the same id again returns the original row
/// instead of logging the student's 40 minutes of homework twice.
public struct NewDayLogEntry: Sendable, Equatable, Codable {
    public let clientEntryId: String
    public var category: JournalCategory
    public var durationMinutes: Int?
    public var startedAt: Date?
    public var endedAt: Date?
    public var subject: String?
    public var content: String?

    public init(
        clientEntryId: String = "ios-\(UUID().uuidString)",
        category: JournalCategory,
        durationMinutes: Int? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        subject: String? = nil,
        content: String? = nil
    ) {
        self.clientEntryId = clientEntryId
        self.category = category
        self.durationMinutes = durationMinutes
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.subject = subject
        self.content = content
    }
}

/// Study MANABU2 recorded by itself (`source: manabu2`) — the study timer and
/// sessions reported after the fact. Not editable here; it is shown so the
/// student can see the day whole.
public struct AutoStudyEntry: Sendable, Codable, Equatable, Identifiable {
    public let sessionId: String
    /// `timer` when the server kept time, `reported` when the device sent it
    /// afterwards.
    public let recordedBy: String?
    public let kind: String?
    public let subject: String?
    public let courseId: String?
    public let lessonId: String?
    public let startedAt: Date?
    public let endedAt: Date?
    public let durationMinutes: Int

    public var id: String { sessionId }
}

/// What the dynamic tests did that day. Its minutes are an estimate and the
/// server deliberately leaves them out of `studyAutoMinutes`; nothing here may
/// add them back in.
public struct PracticeSummary: Sendable, Codable, Equatable {
    public let sessions: Int
    public let answered: Int
    public let correct: Int
    public let minutes: Int

    public static let none = PracticeSummary(sessions: 0, answered: 0, correct: 0, minutes: 0)

    public init(sessions: Int, answered: Int, correct: Int, minutes: Int) {
        self.sessions = sessions
        self.answered = answered
        self.correct = correct
        self.minutes = minutes
    }
}

/// The day's arithmetic, as the server does it.
///
/// **`studySelfMinutes` and `studyAutoMinutes` are never added together.** A
/// student who runs the study timer and also logs 自主学習 for the same hour has
/// one hour, not two, and the server cannot tell which. It hands both numbers
/// to the screen and refuses to choose — so every screen must choose, in view
/// code, and say which one it is showing.
public struct DayTotals: Sendable, Codable, Equatable {
    public let minutesByCategory: [String: Int]
    public let studySelfMinutes: Int
    public let studyAutoMinutes: Int

    public static let empty = DayTotals(minutesByCategory: [:], studySelfMinutes: 0, studyAutoMinutes: 0)

    public init(minutesByCategory: [String: Int], studySelfMinutes: Int, studyAutoMinutes: Int) {
        self.minutesByCategory = minutesByCategory
        self.studySelfMinutes = studySelfMinutes
        self.studyAutoMinutes = studyAutoMinutes
    }

    public func minutes(for category: JournalCategory) -> Int {
        minutesByCategory[category.rawValue] ?? 0
    }

    /// See `headlineStudy(selfMinutes:autoMinutes:)`.
    public var headlineStudy: HeadlineStudy {
        WakaRouteKit.headlineStudy(selfMinutes: studySelfMinutes, autoMinutes: studyAutoMinutes)
    }
}

/// Where a study figure came from.
public enum StudySource: Sendable, Equatable {
    /// The student logged it: 自主学習, 宿題, 塾. Includes everything that
    /// happened away from the app.
    case learner
    /// MANABU2 measured it: the study timer and reported sessions.
    case app

    public var displayName: String {
        switch self {
        case .learner: "自分で記録"
        case .app: "アプリが記録"
        }
    }
}

/// One study figure, and where it came from — for the screens that have room
/// for a single number.
public struct HeadlineStudy: Sendable, Equatable {
    public let minutes: Int
    public let source: StudySource

    public init(minutes: Int, source: StudySource) {
        self.minutes = minutes
        self.source = source
    }
}

/// The one number a screen should show, when it can only show one.
///
/// **The student's own record wins.** The timer only ever sees study done with
/// the app open — it never sees 塾, a paper problem book, or homework at the
/// kitchen table, which for a student sitting entrance exams is most of it.
///
/// **Except when they logged nothing.** `self` is claimed and `auto` is
/// measured, so a day with no entries but a 90-minute timer session is a day
/// they studied for 90 minutes. Printing 「0分」 at that student is worse than
/// either number on its own.
///
/// The two are never added: a student who ran the timer *and* wrote 自主学習 for
/// the same evening has one evening, and nothing here can tell how much of it
/// overlaps. Whichever is shown, the screen says which — that is what
/// `source` is for.
func headlineStudy(selfMinutes: Int, autoMinutes: Int) -> HeadlineStudy {
    selfMinutes == 0 && autoMinutes > 0
        ? HeadlineStudy(minutes: autoMinutes, source: .app)
        : HeadlineStudy(minutes: selfMinutes, source: .learner)
}

/// One day, whole.
public struct JournalDay: Sendable, Codable, Equatable, Identifiable {
    public let date: JournalDate
    public let diary: DiaryEntry?
    public let entries: [DayLogEntry]
    public let autoStudy: [AutoStudyEntry]
    public let practice: PracticeSummary?
    public let totals: DayTotals

    public var id: String { date.text }

    public init(
        date: JournalDate,
        diary: DiaryEntry? = nil,
        entries: [DayLogEntry] = [],
        autoStudy: [AutoStudyEntry] = [],
        practice: PracticeSummary? = nil,
        totals: DayTotals = .empty
    ) {
        self.date = date
        self.diary = diary
        self.entries = entries
        self.autoStudy = autoStudy
        self.practice = practice
        self.totals = totals
    }

    /// Nothing written, nothing logged, nothing recorded.
    ///
    /// The range endpoints return an element for every day including the empty
    /// ones, so this is how a screen tells "no records" from "not loaded" —
    /// without the app inventing days of its own.
    public var isEmpty: Bool {
        diary == nil && entries.isEmpty && autoStudy.isEmpty
    }

    /// Whether the student can still write to this day.
    public var isWritable: Bool { date.isWritable() }
}

/// A day without the diary's words — safe to put on a screen the student shows
/// to a parent.
public struct JournalDaySummary: Sendable, Codable, Equatable, Identifiable {
    public let date: JournalDate
    public let minutesByCategory: [String: Int]
    public let studySelfMinutes: Int
    public let studyAutoMinutes: Int
    public let hasDiary: Bool
    public let focus: Int?
    public let fatigue: Int?
    public let practice: PracticeSummary?

    public var id: String { date.text }

    public func minutes(for category: JournalCategory) -> Int {
        minutesByCategory[category.rawValue] ?? 0
    }

    /// See `headlineStudy(selfMinutes:autoMinutes:)`.
    public var headlineStudy: HeadlineStudy {
        WakaRouteKit.headlineStudy(selfMinutes: studySelfMinutes, autoMinutes: studyAutoMinutes)
    }
}
