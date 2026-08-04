import Foundation
import Testing
@testable import WakaRouteKit

private func path(_ name: String, labels: [String], courses: Int = 0) -> LearningPathSummary {
    LearningPathSummary(id: "p-\(name)", name: name, labels: labels, courseCount: courses)
}

@Suite("Subject catalogue")
struct SubjectCatalogTests {

    @Test("All five 教科 appear, even with no content at all")
    func allSubjectsAlwaysPresent() {
        let grouped = SubjectCatalog.group(paths: [])

        #expect(grouped.count == 5)
        #expect(grouped.map(\.subject.label) == ["国語", "数学", "英語", "理科", "社会"])
        #expect(grouped.allSatisfy { !$0.hasContent })
    }

    @Test("Paths group under the 教科 named in their labels")
    func groupsByLabel() throws {
        let grouped = SubjectCatalog.group(paths: [
            path("数学・数と式", labels: ["数学", "数と式"], courses: 7),
            path("数学・図形", labels: ["数学", "図形"], courses: 5),
            path("英語・文法", labels: ["英語", "文法"], courses: 4)
        ])

        let math = try #require(grouped.first { $0.subject == .math })
        #expect(math.paths.count == 2)
        #expect(math.courseCount == 12)

        let english = try #require(grouped.first { $0.subject == .english })
        #expect(english.paths.count == 1)

        let science = try #require(grouped.first { $0.subject == .science })
        #expect(science.hasContent == false)
    }

    /// The behaviour the convention exists to protect. A path *named*
    /// 「数学・数と式」 but labelled only 理科 belongs to 理科 — the name is
    /// display text, and parsing it would put this path in the wrong subject.
    @Test("Grouping follows the label, never the path name")
    func nameIsNeverParsed() throws {
        let grouped = SubjectCatalog.group(paths: [
            path("数学・数と式", labels: ["理科"])
        ])

        #expect(try #require(grouped.first { $0.subject == .math }).hasContent == false)
        #expect(try #require(grouped.first { $0.subject == .science }).paths.count == 1)
    }

    /// A stray space in a hand-entered label would otherwise remove a whole
    /// subject from the app with no error anywhere.
    @Test("Whitespace and full-width spaces in labels are tolerated")
    func normalisesWhitespace() throws {
        let grouped = SubjectCatalog.group(paths: [
            path("A", labels: [" 数学 "]),
            path("B", labels: ["\u{3000}数学"]),
            path("C", labels: ["数学\n"])
        ])

        #expect(try #require(grouped.first { $0.subject == .math }).paths.count == 3)
    }

    /// Content nobody can reach is worse than content shown as mislabelled —
    /// a typo in a label produces no other symptom.
    @Test("Paths with no recognised 教科 label are reported, not discarded")
    func surfacesUnclassifiedPaths() {
        let paths = [
            path("数学・数と式", labels: ["数学"]),
            path("課外・探究", labels: ["探究"]),
            path("ラベルなし", labels: [])
        ]

        let orphans = SubjectCatalog.unclassified(paths: paths)
        #expect(orphans.map(\.name) == ["課外・探究", "ラベルなし"])
    }

    @Test("The 領域 label is the one that is not a 教科")
    func findsDomainLabel() {
        #expect(SubjectCatalog.domainLabel(of: path("A", labels: ["数学", "数と式"])) == "数と式")
        #expect(SubjectCatalog.domainLabel(of: path("B", labels: ["数学"])) == nil)
    }

    @Test("A path labelled with two 教科 appears under both")
    func multipleSubjectLabels() throws {
        let grouped = SubjectCatalog.group(paths: [path("横断", labels: ["数学", "理科"])])

        #expect(try #require(grouped.first { $0.subject == .math }).paths.count == 1)
        #expect(try #require(grouped.first { $0.subject == .science }).paths.count == 1)
    }
}

@Suite("Content decoding")
struct ContentDecodingTests {

    @Test("Path list decodes with labels")
    func decodesPathList() throws {
        let json = """
        { "items": [ { "id": "p1", "name": "数学・数と式", "description": null,
                       "culture": "ja-JP", "isPublic": true,
                       "labels": ["数学", "数と式"], "courseCount": 7 } ],
          "page": 1, "pageSize": 24, "totalItems": 1, "totalPages": 1 }
        """
        struct Page: Decodable { let items: [LearningPathSummary] }
        let page = try JSONDecoder.wakaRoute.decode(Page.self, from: Data(json.utf8))

        #expect(page.items.first?.labels == ["数学", "数と式"])
        #expect(page.items.first?.courseCount == 7)
    }

    /// The OpenAPI document types every count as `['integer','string']`, so the
    /// server may send either. One quoted number must not fail a whole screen.
    @Test("Counts decode whether sent as numbers or strings")
    func toleratesStringNumbers() throws {
        let json = """
        { "id": "c1", "title": "文字を用いた式", "lessonCount": "5",
          "sectionCount": 2, "estimatedMinutes": "30" }
        """
        let course = try JSONDecoder.wakaRoute.decode(CourseSummary.self, from: Data(json.utf8))

        #expect(course.lessonCount == 5)
        #expect(course.sectionCount == 2)
        #expect(course.estimatedMinutes == 30)
    }

    @Test("Course lessons come back in section then lesson order")
    func lessonsAreOrdered() throws {
        let json = """
        { "id": "c1", "title": "コース", "sections": [
            { "id": "s2", "title": "後半", "orderIndex": 2, "lessons": [
                { "id": "l3", "sectionId": "s2", "title": "3", "orderIndex": 1 } ] },
            { "id": "s1", "title": "前半", "orderIndex": 1, "lessons": [
                { "id": "l2", "sectionId": "s1", "title": "2", "orderIndex": 2 },
                { "id": "l1", "sectionId": "s1", "title": "1", "orderIndex": 1 } ] } ] }
        """
        let course = try JSONDecoder.wakaRoute.decode(CourseDetail.self, from: Data(json.utf8))

        #expect(course.lessons.map(\.id) == ["l1", "l2", "l3"])
    }

    @Test("A course with no sections is empty, not an error")
    func emptyCourseIsSafe() throws {
        let json = #"{ "id": "c1", "title": "準備中のコース" }"#
        let course = try JSONDecoder.wakaRoute.decode(CourseDetail.self, from: Data(json.utf8))

        #expect(course.sections.isEmpty)
        #expect(course.lessons.isEmpty)
    }
}
