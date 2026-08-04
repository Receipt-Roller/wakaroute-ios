import Foundation
import Testing
@testable import WakaRouteKit

/// The shape of `GET /api/v1/me` as captured on 2026-08-02, including the
/// organization member list the server currently returns (LMS-DEV t-d1bea74).
/// Kept realistic precisely so the test proves we ignore it.
///
/// **The user ids are placeholders.** The captured response carried real
/// account ids, including an organization administrator's — publishing those in
/// a public repository would leak exactly what t-d1bea74 was raised about. The
/// shape is what this test needs; the values are not.
private let liveMeResponse = """
{
  "user": {
    "id": "00000000-0000-4000-8000-000000000001",
    "email": "",
    "displayName": null,
    "profileImageUrl": "/images/default-avatar.png",
    "preferredCulture": "ja-JP",
    "organizationId": null,
    "completedLessons": 0,
    "isDeactivated": false
  },
  "organizations": [
    {
      "id": "a461577a-3410-4c98-b1d5-db729f3444a1",
      "name": "wakaroute",
      "displayName": "ワカルート",
      "seatCount": 5,
      "members": [
        { "userId": "00000000-0000-4000-8000-00000000000a", "isLearner": true, "isOrgAdmin": false },
        { "userId": "00000000-0000-4000-8000-00000000000b", "isLearner": false, "isOrgAdmin": true }
      ]
    }
  ]
}
"""

@Suite("Learner profile")
struct LearnerProfileTests {

    @Test("Decodes the live /me response")
    func decodesLiveResponse() throws {
        let profile = try JSONDecoder.wakaRoute.decode(LearnerProfile.self, from: Data(liveMeResponse.utf8))

        #expect(profile.userId == "00000000-0000-4000-8000-000000000001")
        #expect(profile.preferredCulture == "ja-JP")
        #expect(profile.organizationId == "a461577a-3410-4c98-b1d5-db729f3444a1")
    }

    /// A device-registered account has no email and no name. That is the
    /// intended state for a minor, not missing data.
    @Test("An unlinked account reads as not linked, without inventing a name")
    func unlinkedAccountHasNoIdentity() throws {
        let profile = try JSONDecoder.wakaRoute.decode(LearnerProfile.self, from: Data(liveMeResponse.utf8))

        #expect(profile.email.isEmpty)
        #expect(profile.displayName == nil)
        #expect(profile.isLinked == false)
    }

    /// The type has no member list to hold, so other students' identifiers
    /// cannot be stored, logged, or rendered by accident.
    @Test("Other members' identifiers are not decoded at all")
    func memberListIsNotRetained() throws {
        let profile = try JSONDecoder.wakaRoute.decode(LearnerProfile.self, from: Data(liveMeResponse.utf8))

        let mirrored = String(describing: Mirror(reflecting: profile).children.map { "\($0.value)" })
        #expect(!mirrored.contains("6b5c380f"), "Another learner's id reached our model.")
        #expect(!mirrored.contains("58e3fbea"), "The admin's id reached our model.")
    }

    @Test("A missing organizations array is not a failure")
    func missingOrganizationsIsSafe() throws {
        let json = #"{ "user": { "id": "u-1", "email": "" } }"#
        let profile = try JSONDecoder.wakaRoute.decode(LearnerProfile.self, from: Data(json.utf8))

        #expect(profile.userId == "u-1")
        #expect(profile.organizationId == nil)
    }
}

@Suite("Target schools")
struct TargetSchoolTests {

    /// Captured from `PUT /api/v1/me/target-schools`. Note the binding deadline
    /// is the 第二志望's date — the earlier one.
    private let liveResponse = """
    {
      "goals": [
        { "type": "high_school", "source": "wakaroute", "externalId": "wk_d107320361045",
          "name": "郡山女子大学附属高等学校", "rank": 0, "targetDate": "2027-03-05" },
        { "type": "high_school", "source": "wakaroute", "externalId": "wk_test_0002",
          "name": "市立 みなみ高等学校", "rank": 1, "targetDate": "2027-02-18" }
      ],
      "bindingDeadline": "2027-02-18",
      "daysRemaining": 200
    }
    """

    @Test("Decodes the list with rank and binding deadline")
    func decodesList() throws {
        let list = try JSONDecoder.wakaRoute.decode(TargetSchoolList.self, from: Data(liveResponse.utf8))

        #expect(list.goals.count == 2)
        #expect(list.daysRemaining == 200)
        #expect(try #require(list.primary).externalId == "wk_d107320361045")
    }

    /// The deadline that constrains preparation is the soonest exam, which here
    /// belongs to the 第二志望. Reading the 第一志望's date would be 15 days late.
    @Test("The binding deadline is the earliest exam, not the 第一志望's")
    func bindingDeadlineIsNotThePrimarySchool() throws {
        let list = try JSONDecoder.wakaRoute.decode(TargetSchoolList.self, from: Data(liveResponse.utf8))

        #expect(list.bindingDeadline == "2027-02-18")
        #expect(try #require(list.primary).targetDate == "2027-03-05")
        #expect(list.bindingDeadline != list.primary?.targetDate)
    }

    @Test("Preference labels follow Japanese convention, then fall back")
    func preferenceLabels() {
        #expect(TargetSchoolList.preferenceLabel(at: 0) == "第一志望")
        #expect(TargetSchoolList.preferenceLabel(at: 2) == "第三志望")
        #expect(TargetSchoolList.preferenceLabel(at: 3) == "志望校4")
    }

    @Test("An empty list decodes without a deadline")
    func emptyListIsSafe() throws {
        let json = #"{ "goals": [], "bindingDeadline": null, "daysRemaining": null }"#
        let list = try JSONDecoder.wakaRoute.decode(TargetSchoolList.self, from: Data(json.utf8))

        #expect(list.goals.isEmpty)
        #expect(list.primary == nil)
        #expect(list.daysRemaining == nil)
    }
}

@Suite("Exam date arithmetic")
struct ExamDateTests {

    private let jst: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }()

    private func at(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return formatter.date(from: iso)!
    }

    private func school(_ date: String?) -> TargetSchool {
        TargetSchool(externalId: "wk_1", name: "県立高校", targetDate: date)
    }

    @Test("Counts whole days to the exam")
    func countsWholeDays() {
        let days = school("2027-02-20").daysRemaining(from: at("2027-02-01T22:30:00+09:00"), calendar: jst)
        #expect(days == 19)
    }

    /// Studying late must not make tomorrow's exam read as today's.
    @Test("Time of day does not shift the count")
    func timeOfDayDoesNotShift() {
        let target = school("2027-02-20")
        #expect(target.daysRemaining(from: at("2027-02-19T07:00:00+09:00"), calendar: jst) == 1)
        #expect(target.daysRemaining(from: at("2027-02-19T23:50:00+09:00"), calendar: jst) == 1)
    }

    @Test("A past exam reports zero, never a negative countdown")
    func pastExamClampsToZero() {
        #expect(school("2026-02-20").daysRemaining(from: at("2026-06-01T09:00:00+09:00"), calendar: jst) == 0)
    }

    @Test("A missing or malformed date is nil, not a crash or a wrong number")
    func badDatesAreNil() {
        #expect(school(nil).daysRemaining(from: Date(), calendar: jst) == nil)
        #expect(school("not-a-date").daysRemaining(from: Date(), calendar: jst) == nil)
        #expect(school("2027-02").daysRemaining(from: Date(), calendar: jst) == nil)
    }
}
