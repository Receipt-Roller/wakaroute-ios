import Foundation
import Testing
@testable import WakaRouteKit

@Suite("The service's own documents")
struct LegalDocumentTests {

    @Test("Every document is in the bundle and parses into something readable", arguments: LegalDocument.allCases)
    func everyDocumentRenders(document: LegalDocument) throws {
        let html = try #require(document.html(), "\(document.title) is missing from the bundle.")
        #expect(html.contains("<h1>"))

        let blocks = document.blocks()
        #expect(blocks.count > 3, "\(document.title) parsed into almost nothing — check the markup.")

        guard case let .heading(level, text) = blocks.first else {
            Issue.record("\(document.title) does not start with a heading.")
            return
        }
        #expect(level == 1)
        #expect(text.plain == document.title)
    }

    /// 【運営者名】 shipped in a privacy policy is a legal document that names
    /// nobody, and it would reach students.
    ///
    /// This spent a while as a known issue while 運営者名 / 連絡先 / 保存期間 /
    /// 免責 were being decided — green run, outstanding items reported every
    /// time. All four are settled now (t-1fa7240), so it is an ordinary
    /// assertion again and a new placeholder cannot ship by being forgotten.
    @Test("No 【placeholder】 is left in any document", arguments: LegalDocument.allCases)
    func noPlaceholdersRemain(document: LegalDocument) {
        let remaining = document.placeholders()

        #expect(
            remaining.isEmpty,
            "\(document.title) still needs: \(remaining.joined(separator: " / "))"
        )
    }

    /// The privacy policy has to describe the app that exists, not a plausible
    /// one. These are the specific claims worth pinning: each corresponds to
    /// something the code either does or refuses to do.
    @Test("The privacy policy states what the app actually collects")
    func privacyMatchesTheApp() throws {
        let html = try #require(LegalDocument.privacy.html())

        for promise in ["アクセス解析", "広告", "位置情報", "キーチェーン", "MANABU2"] {
            #expect(html.contains(promise), "The policy should address \(promise).")
        }
    }

    @Test("The parent guide says the record is tied to the device")
    func parentGuideExplainsTheRisk() throws {
        let html = try #require(LegalDocument.forParents.html())
        #expect(html.contains("機種変更"), "Losing a record on a new phone is the thing parents most need told.")
    }
}
