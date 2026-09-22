import Foundation

/// A day in the 受験日記, as the API counts days.
///
/// The journal is keyed by **Japanese calendar days** (`yyyy-MM-dd`), not by
/// instants. Carrying these as `Date` is how the 9-hour class of bug gets in:
/// 2026-09-21T00:30 JST is still 2026-09-20 in UTC, so a diary written just
/// after midnight would land on yesterday. The value is kept as the server
/// writes it, and only converted where a calendar is genuinely needed.
public struct JournalDate: Hashable, Sendable, Codable, CustomStringConvertible {
    /// `yyyy-MM-dd`.
    public let text: String

    public var description: String { text }

    public init?(_ text: String) {
        let parts = text.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) })
        else { return nil }
        self.text = text
    }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let date = JournalDate(text) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Not a yyyy-MM-dd date: \(text)")
            )
        }
        self = date
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }

    /// Japan, always — the student's day does not move with the device's zone.
    public static let zone = TimeZone(identifier: "Asia/Tokyo") ?? .current

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    public static func today(_ now: Date = Date()) -> JournalDate {
        from(now)
    }

    public static func from(_ instant: Date) -> JournalDate {
        let parts = calendar.dateComponents([.year, .month, .day], from: instant)
        let text = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        return JournalDate(text) ?? JournalDate("1970-01-01")!
    }

    /// Midnight in Japan, for sorting and for working out how far apart two
    /// days are.
    public var startOfDay: Date {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        var components = DateComponents()
        components.year = parts.count == 3 ? parts[0] : 1970
        components.month = parts.count == 3 ? parts[1] : 1
        components.day = parts.count == 3 ? parts[2] : 1
        return Self.calendar.date(from: components) ?? .distantPast
    }

    public func adding(days: Int) -> JournalDate {
        let moved = Self.calendar.date(byAdding: .day, value: days, to: startOfDay) ?? startOfDay
        return .from(moved)
    }

    public func daysSince(_ other: JournalDate) -> Int {
        Self.calendar.dateComponents([.day], from: other.startOfDay, to: startOfDay).day ?? 0
    }

    /// How far back the API accepts a write.
    public static let writableDaysBack = 31

    /// Whether the server will accept a write for this day.
    ///
    /// Checked before sending so the student is told in the moment, rather than
    /// meeting a 400 `date_not_writable` after typing a diary entry.
    public func isWritable(on today: JournalDate = .today()) -> Bool {
        let difference = today.daysSince(self)
        return difference >= 0 && difference <= Self.writableDaysBack
    }
}

extension JournalDate: Comparable {
    public static func < (lhs: JournalDate, rhs: JournalDate) -> Bool { lhs.text < rhs.text }
}
