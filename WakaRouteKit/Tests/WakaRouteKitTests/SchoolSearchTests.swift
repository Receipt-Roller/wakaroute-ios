import Foundation
import Testing
@testable import WakaRouteKit

/// Captured verbatim from https://wakaroute.com/api/schools on 2026-08-02.
/// Kept real rather than idealised so the nullable fields stay exercised.
private let liveFixture = """
{
  "asOf": "2025-05-01",
  "totalCount": 13,
  "page": 1,
  "pageSize": 2,
  "totalPages": 7,
  "items": [
    {
      "id": "wk_d107320361045",
      "name": "郡山女子大学附属高等学校",
      "nameKana": null,
      "prefectureCode": "07",
      "prefecture": "福島県",
      "address": "福島県郡山市開成三丁目２５番２号",
      "postalCode": "963-8503",
      "ownership": "private",
      "campusType": "main",
      "openedOn": "2020/12/22",
      "lastVerifiedAt": "2025-05-01",
      "latitude": null,
      "longitude": null,
      "officialUrl": null,
      "tags": [],
      "ownershipLabel": "私立",
      "campusTypeLabel": "本校"
    }
  ]
}
"""

@Suite("School search")
struct SchoolSearchTests {

    @Test("Decodes the live response, nulls included")
    func decodesLiveShape() throws {
        let page = try JSONDecoder.wakaRoute.decode(SchoolSearchPage.self, from: Data(liveFixture.utf8))

        #expect(page.totalCount == 13)
        #expect(page.asOf == "2025-05-01")

        let school = try #require(page.items.first)
        #expect(school.id == "wk_d107320361045")
        #expect(school.ownership == .private)
        #expect(school.ownershipLabel == "私立")
        #expect(school.nameKana == nil)
        #expect(school.latitude == nil)
    }

    @Test("pageSize is clamped to the documented maximum of 48")
    func clampsPageSize() {
        #expect(SchoolSearchQuery(pageSize: 500).pageSize == 48)
        #expect(SchoolSearchQuery(pageSize: 0).pageSize == 1)
        #expect(SchoolSearchQuery(page: -3).page == 1)
    }

    @Test("Only the supplied filters become query items")
    func buildsMinimalQuery() {
        let names = SchoolSearchQuery(keyword: "開成", ownership: .private)
            .queryItems()
            .map(\.name)

        #expect(names.contains("q"))
        #expect(names.contains("ownership"))
        #expect(!names.contains("prefecture"))
    }

    /// A malformed payload must surface as an error, never a crash.
    @Test("Undecodable responses do not crash")
    func undecodableIsAnError() {
        #expect(throws: (any Error).self) {
            try JSONDecoder.wakaRoute.decode(SchoolSearchPage.self, from: Data(#"{"nope":1}"#.utf8))
        }
    }
}
