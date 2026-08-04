import Foundation

/// The learner, as this app needs them.
///
/// Deliberately narrow. `GET /api/v1/me` also returns the caller's
/// organizations with their full member list — every other student's user id
/// and role flags (LMS-DEV t-d1bea74). Decoding only these fields means that
/// data is never held in memory, written to disk, or logged. The fix belongs
/// on the server; this keeps our exposure to the wire.
public struct LearnerProfile: Sendable, Equatable {
    public let userId: String
    public let email: String
    public let displayName: String?
    public let preferredCulture: String?
    public let organizationId: String?

    /// An account with no email has not been linked yet, and progress lives or
    /// dies with the device.
    public var isLinked: Bool { !email.isEmpty }
}

extension LearnerProfile: Decodable {
    private enum RootKeys: String, CodingKey { case user, organizations }
    private enum UserKeys: String, CodingKey {
        case id, email, displayName, preferredCulture
    }
    private enum OrganizationKeys: String, CodingKey { case id }

    public init(from decoder: any Decoder) throws {
        let root = try decoder.container(keyedBy: RootKeys.self)
        let user = try root.nestedContainer(keyedBy: UserKeys.self, forKey: .user)

        userId = try user.decode(String.self, forKey: .id)
        email = try user.decodeIfPresent(String.self, forKey: .email) ?? ""
        displayName = try user.decodeIfPresent(String.self, forKey: .displayName)
        preferredCulture = try user.decodeIfPresent(String.self, forKey: .preferredCulture)

        // Only the id of the first organization. `members` is never read.
        var organizations = try? root.nestedUnkeyedContainer(forKey: .organizations)
        if var organizations, !organizations.isAtEnd {
            let first = try organizations.nestedContainer(keyedBy: OrganizationKeys.self)
            organizationId = try first.decodeIfPresent(String.self, forKey: .id)
        } else {
            organizationId = nil
        }
    }
}

/// A 志望校, as stored on the server.
public struct TargetSchool: Sendable, Equatable, Identifiable, Codable {
    /// `wakaroute` for entries chosen from the school catalogue.
    public let source: String
    /// The WakaRoute catalogue id (`wk_…`).
    public let externalId: String
    public let name: String
    /// 0 is 第一志望.
    public let rank: Int
    public let targetDate: String?

    public var id: String { externalId }

    public init(source: String = "wakaroute", externalId: String, name: String, rank: Int = 0, targetDate: String? = nil) {
        self.source = source
        self.externalId = externalId
        self.name = name
        self.rank = rank
        self.targetDate = targetDate
    }

    /// The exam date, parsed from the server's `yyyy-MM-dd`.
    public func examDate(calendar: Calendar = .current) -> Date? {
        guard let targetDate else { return nil }
        var components = DateComponents()
        let parts = targetDate.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        return calendar.date(from: components)
    }

    /// Whole days until this school's exam, counted in calendar days so the
    /// number matches the one on the student's wall calendar.
    public func daysRemaining(from now: Date, calendar: Calendar = .current) -> Int? {
        guard let exam = examDate(calendar: calendar) else { return nil }
        let today = calendar.startOfDay(for: now)
        let target = calendar.startOfDay(for: exam)
        guard let days = calendar.dateComponents([.day], from: today, to: target).day else { return nil }
        return max(0, days)
    }
}

/// The 志望校 list plus the deadline that actually constrains preparation.
public struct TargetSchoolList: Sendable, Equatable, Decodable {
    public let goals: [TargetSchool]
    /// The **soonest** exam across all targets — frequently a safety school
    /// rather than the 第一志望. The server computes this; the client must not
    /// second-guess it by reading the 第一志望's date.
    public let bindingDeadline: String?
    public let daysRemaining: Int?

    public var primary: TargetSchool? {
        goals.min { $0.rank < $1.rank }
    }

    public var alternatives: [TargetSchool] {
        goals.sorted { $0.rank < $1.rank }.dropFirst().map { $0 }
    }

    /// True when the soonest exam is not the 第一志望's — worth telling the
    /// student, because that earlier date is the one preparation must meet.
    public var deadlineIsNotPrimary: Bool {
        guard let bindingDeadline, let primaryDate = primary?.targetDate else { return false }
        return bindingDeadline != primaryDate
    }

    public var schoolWithEarliestExam: TargetSchool? {
        guard let bindingDeadline else { return nil }
        return goals.first { $0.targetDate == bindingDeadline }
    }

    /// Japanese preference labels, by rank position.
    public static func preferenceLabel(at index: Int) -> String {
        switch index {
        case 0: "第一志望"
        case 1: "第二志望"
        case 2: "第三志望"
        default: "志望校\(index + 1)"
        }
    }

    public init(goals: [TargetSchool], bindingDeadline: String? = nil, daysRemaining: Int? = nil) {
        self.goals = goals
        self.bindingDeadline = bindingDeadline
        self.daysRemaining = daysRemaining
    }
}

/// Reads and writes the learner's 志望校.
///
/// An abstraction so the design-review build can supply fixtures without the
/// screens knowing which they are talking to.
public protocol TargetSchoolsRepository: Sendable {
    func targetSchools() async throws -> TargetSchoolList
    func replaceTargetSchools(_ schools: [TargetSchool]) async throws -> TargetSchoolList
}
