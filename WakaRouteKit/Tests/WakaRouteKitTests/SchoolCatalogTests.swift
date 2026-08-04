import Foundation
import Testing
@testable import WakaRouteKit

private let jst: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    return calendar
}()

private func day(_ iso: String) -> Date {
    CatalogDate.parse(iso, calendar: jst)!
}

/// Shaped from `SchoolCatalogModels.cs`. Nothing in production populates these
/// yet, so these fixtures are the only exercise this code gets — written from
/// the C# definitions rather than from observed traffic, and worth re-checking
/// against a real payload once the catalogue publishes one.
private let populatedDetail = """
{
  "school": {
    "id": "wk_d107320361045", "name": "県立 開成高等学校", "nameKana": null,
    "prefectureCode": "07", "prefecture": "福島県", "address": "福島県…",
    "ownership": "public", "ownershipLabel": "公立", "campusTypeLabel": "本校",
    "latitude": null, "longitude": null, "officialUrl": null
  },
  "profile": { "schoolId": "wk_d107320361045", "gender": "共学" },
  "decisionGuide": null,
  "examSchedules": [
    { "schoolId": "wk_d107320361045", "academicYear": 2027, "selection": "general",
      "selectionLabel": "一般選抜", "status": "published", "statusLabel": "発表済",
      "applicationPeriod": "2027-02-08〜2027-02-12",
      "testDates": ["2027-03-05", "2027-03-06"], "resultDate": "2027-03-15",
      "detailsStatus": "final", "detailsStatusLabel": "確定",
      "officialPublishedAt": null, "verifiedAt": "2026-08-01",
      "notes": ["面接あり"], "sources": [{ "name": "県教委", "url": "https://example.jp" }] },
    { "schoolId": "wk_d107320361045", "academicYear": 2027, "selection": "recommend",
      "selectionLabel": "推薦選抜", "statusLabel": "発表済",
      "testDates": ["2027-01-28"], "resultDate": "2027-02-03", "notes": [] }
  ],
  "admissions": [
    { "schoolId": "wk_d107320361045", "academicYear": 2026, "selectionLabel": "一般選抜",
      "attendanceType": "full", "department": "普通科", "capacity": 240,
      "applicants": 312, "examinees": 300, "admitted": 245, "enrolled": 240, "note": null }
  ],
  "deviationScores": [
    { "schoolId": "wk_d107320361045", "academicYear": 2025, "provider": "A社",
      "value": null, "valueLow": 58, "valueHigh": 62, "population": "県内公立",
      "sourceUrl": "https://example.jp", "license": "CC", "verifiedAt": "2025-06-01" },
    { "schoolId": "wk_d107320361045", "academicYear": 2026, "provider": "B社",
      "value": 61, "valueLow": null, "valueHigh": null, "population": "県内公立",
      "sourceUrl": "https://example.jp", "license": "CC", "verifiedAt": "2026-06-01" }
  ]
}
"""

/// Exactly what production returns today.
private let emptyDetail = """
{ "school": { "id": "wk_1", "name": "テスト高校", "prefectureCode": "13" },
  "profile": null, "decisionGuide": null,
  "examSchedules": [], "admissions": [], "deviationScores": [] }
"""

@Suite("School catalogue detail")
struct SchoolCatalogTests {

    private func decode(_ json: String) throws -> SchoolDetail {
        try JSONDecoder.wakaRoute.decode(SchoolDetail.self, from: Data(json.utf8))
    }

    @Test("Decodes the empty payload production returns today")
    func decodesEmptyPayload() throws {
        let detail = try decode(emptyDetail)

        #expect(detail.school.id == "wk_1")
        #expect(detail.examSchedules.isEmpty)
        #expect(detail.suggestedExamDate(after: day("2026-08-02"), calendar: jst) == nil)
        #expect(detail.latestDeviationScore == nil)
    }

    @Test("Decodes a fully populated payload, ignoring fields we do not model")
    func decodesPopulatedPayload() throws {
        let detail = try decode(populatedDetail)

        #expect(detail.examSchedules.count == 2)
        #expect(detail.admissions.count == 1)
        #expect(detail.deviationScores.count == 2)
        #expect(detail.examSchedules[0].testDates == ["2027-03-05", "2027-03-06"])
        #expect(detail.examSchedules[0].notes == ["面接あり"])
    }

    /// 推薦 sits in January, 一般 in March. Adding this school as a 志望校 should
    /// offer the January date — the first one the student actually has to be
    /// ready for.
    @Test("Suggests the earliest upcoming sitting across all selections")
    func suggestsEarliestUpcomingDate() throws {
        let detail = try decode(populatedDetail)
        let suggested = detail.suggestedExamDate(after: day("2026-08-02"), calendar: jst)

        #expect(suggested == day("2027-01-28"))
    }

    /// A catalogue carrying past years must not propose a date already gone.
    @Test("Dates in the past are never suggested")
    func skipsPastDates() throws {
        let detail = try decode(populatedDetail)
        let suggested = detail.suggestedExamDate(after: day("2027-02-01"), calendar: jst)

        #expect(suggested == day("2027-03-05"), "推薦 has passed, so 一般 is next.")
        #expect(detail.suggestedExamDate(after: day("2027-06-01"), calendar: jst) == nil)
    }

    @Test("A schedule published without dates does not crash the suggestion")
    func handlesScheduleWithoutDates() throws {
        let json = """
        { "school": { "id": "wk_1", "name": "テスト" },
          "examSchedules": [ { "academicYear": 2027, "statusLabel": "未発表", "testDates": [] } ] }
        """
        let detail = try decode(json)

        #expect(detail.examSchedules.count == 1)
        #expect(detail.suggestedExamDate(after: day("2026-08-02"), calendar: jst) == nil)
    }

    @Test("The newest 偏差値 wins, whatever the provider")
    func latestDeviationScore() throws {
        let detail = try decode(populatedDetail)
        let latest = try #require(detail.latestDeviationScore)

        #expect(latest.academicYear == 2026)
        #expect(latest.displayText == "61")
    }

    @Test("A banded 偏差値 renders as a range and averages to its midpoint")
    func bandedDeviationScore() throws {
        let detail = try decode(populatedDetail)
        let banded = try #require(detail.deviationScores.first { $0.academicYear == 2025 })

        #expect(banded.displayText == "58〜62")
        #expect(banded.representativeValue == 60)
    }

    /// With every figure published, 実質倍率 is the one that describes what a
    /// candidate faced: 300 sat, 245 passed. Not 312/240, which counts people
    /// who applied and then withdrew.
    @Test("実質倍率 is preferred when results are published")
    func prefersActualRatio() throws {
        let detail = try decode(populatedDetail)
        let ratio = try #require(detail.admissions.first?.competitionRatio)

        #expect(ratio.kind == .actual)
        #expect(ratio.kind.label == "実質倍率")
        #expect(abs(ratio.value - (300.0 / 245.0)) < 0.001)
    }

    @Test("受験倍率 when results are missing but the sitting happened")
    func fallsBackToExamineeRatio() throws {
        let json = """
        { "school": { "id": "wk_1", "name": "テスト" },
          "admissions": [ { "academicYear": 2027, "capacity": 200, "applicants": 260, "examinees": 250 } ] }
        """
        let ratio = try #require(try decode(json).admissions.first?.competitionRatio)

        #expect(ratio.kind == .examinee)
        #expect(abs(ratio.value - 1.25) < 0.001)
    }

    @Test("志願倍率 before the exam, and labelled as such")
    func fallsBackToApplicantRatio() throws {
        let json = """
        { "school": { "id": "wk_1", "name": "テスト" },
          "admissions": [ { "academicYear": 2027, "capacity": 200, "applicants": 260 } ] }
        """
        let ratio = try #require(try decode(json).admissions.first?.competitionRatio)

        #expect(ratio.kind == .applicant)
        #expect(ratio.kind.label == "志願倍率")
        #expect(abs(ratio.value - 1.3) < 0.001)
    }

    /// The three ratios differ for the same school. Conflating them under one
    /// label would make our number look wrong against a published figure.
    @Test("The three ratios are genuinely different numbers")
    func ratiosAreNotInterchangeable() {
        let full = SchoolAdmissionResult.CompetitionRatio(value: 300.0 / 245.0, kind: .actual)
        #expect(abs(full.value - 1.224) < 0.01)
        #expect(abs(300.0 / 240.0 - 1.25) < 0.01)
        #expect(abs(312.0 / 240.0 - 1.30) < 0.01)
    }

    @Test("Missing numbers give no ratio rather than a misleading one")
    func noRatioWithoutNumbers() throws {
        let json = """
        { "school": { "id": "wk_1", "name": "テスト" },
          "admissions": [ { "academicYear": 2027, "capacity": 0, "applicants": 260 } ] }
        """
        #expect(try decode(json).admissions.first?.competitionRatio == nil)
    }
}
