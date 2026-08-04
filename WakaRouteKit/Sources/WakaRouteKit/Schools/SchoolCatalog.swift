import Foundation

/// 入試日程 for one selection (推薦, 一般, …) in one academic year.
///
/// Mirrors `SchoolExamSchedule` in wakaroute-web. `sources` is deliberately not
/// modelled — it is provenance for the web site, and decoding ignores keys we
/// do not declare.
public struct SchoolExamSchedule: Decodable, Sendable, Equatable {
    public let academicYear: Int
    public let selection: String?
    public let selectionLabel: String?
    /// 未発表 / 発表済 etc. A schedule can exist before its dates are fixed.
    public let statusLabel: String?
    public let applicationPeriod: String?
    /// `yyyy-MM-dd`. More than one when a selection runs over several days.
    public let testDates: [String]
    public let resultDate: String?
    public let detailsStatusLabel: String?
    public let notes: [String]

    private enum CodingKeys: String, CodingKey {
        case academicYear, selection, selectionLabel, statusLabel
        case applicationPeriod, testDates, resultDate, detailsStatusLabel, notes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        academicYear = try container.decodeIfPresent(Int.self, forKey: .academicYear) ?? 0
        selection = try container.decodeIfPresent(String.self, forKey: .selection)
        selectionLabel = try container.decodeIfPresent(String.self, forKey: .selectionLabel)
        statusLabel = try container.decodeIfPresent(String.self, forKey: .statusLabel)
        applicationPeriod = try container.decodeIfPresent(String.self, forKey: .applicationPeriod)
        testDates = try container.decodeIfPresent([String].self, forKey: .testDates) ?? []
        resultDate = try container.decodeIfPresent(String.self, forKey: .resultDate)
        detailsStatusLabel = try container.decodeIfPresent(String.self, forKey: .detailsStatusLabel)
        notes = try container.decodeIfPresent([String].self, forKey: .notes) ?? []
    }

    /// The first sitting, as a date. Nil when the school has published a
    /// schedule but not yet the dates — a real and common state.
    public func firstTestDate(calendar: Calendar = .current) -> Date? {
        testDates.compactMap { CatalogDate.parse($0, calendar: calendar) }.min()
    }
}

/// 偏差値 from one provider, for one year.
public struct SchoolDeviationScore: Decodable, Sendable, Equatable {
    public let academicYear: Int
    public let provider: String?
    public let value: Double?
    public let valueLow: Double?
    public let valueHigh: Double?
    /// Which cohort the figure describes — a bare number means little without it.
    public let population: String?
    public let sourceUrl: String?

    /// A single figure when there is one, otherwise the midpoint of the band.
    public var representativeValue: Double? {
        if let value { return value }
        guard let low = valueLow, let high = valueHigh else { return valueLow ?? valueHigh }
        return (low + high) / 2
    }

    public var displayText: String? {
        if let value { return String(format: "%.0f", value) }
        if let low = valueLow, let high = valueHigh { return String(format: "%.0f〜%.0f", low, high) }
        if let single = valueLow ?? valueHigh { return String(format: "%.0f", single) }
        return nil
    }
}

/// 入試結果 — applicants against capacity, per selection and department.
public struct SchoolAdmissionResult: Decodable, Sendable, Equatable {
    public let academicYear: Int
    public let selectionLabel: String?
    public let department: String?
    public let capacity: Int?
    public let applicants: Int?
    public let examinees: Int?
    public let admitted: Int?
    public let enrolled: Int?
    public let note: String?

    /// 倍率, carrying which of the three it is.
    ///
    /// These are not interchangeable and must never share a label. For a school
    /// with 312 applicants, 300 examinees, 240 places and 245 admitted:
    /// 志願倍率 1.30, 受験倍率 1.25, 実質倍率 1.22. Showing 1.22 as 「倍率」 next
    /// to a published 志願倍率 of 1.30 would look like an error, or worse, be
    /// taken as one.
    public struct CompetitionRatio: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            /// 受験者 ÷ 合格者 — what a candidate actually faced.
            case actual
            /// 受験者 ÷ 募集定員.
            case examinee
            /// 志願者 ÷ 募集定員 — published before the exam.
            case applicant

            public var label: String {
                switch self {
                case .actual: "実質倍率"
                case .examinee: "受験倍率"
                case .applicant: "志願倍率"
                }
            }

            /// What the number does and does not tell the student.
            public var explanation: String {
                switch self {
                case .actual: "受験した人数を合格した人数で割った、実際の競争率です。"
                case .examinee: "受験した人数を募集定員で割った値です。"
                case .applicant: "出願した人数を募集定員で割った、入試前の値です。"
                }
            }
        }

        public let value: Double
        public let kind: Kind
    }

    /// The most informative ratio the published numbers support.
    ///
    /// 実質倍率 first because it reflects the actual outcome; 志願倍率 last
    /// because withdrawals mean it usually overstates the competition.
    public var competitionRatio: CompetitionRatio? {
        if let examinees, let admitted, admitted > 0 {
            return CompetitionRatio(value: Double(examinees) / Double(admitted), kind: .actual)
        }
        if let examinees, let capacity, capacity > 0 {
            return CompetitionRatio(value: Double(examinees) / Double(capacity), kind: .examinee)
        }
        if let applicants, let capacity, capacity > 0 {
            return CompetitionRatio(value: Double(applicants) / Double(capacity), kind: .applicant)
        }
        return nil
    }
}

enum CatalogDate {
    /// The catalogue writes plain `yyyy-MM-dd`, with no time or zone.
    static func parse(_ text: String, calendar: Calendar = .current) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        return calendar.date(from: components)
    }
}
