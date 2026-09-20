import Foundation
import Testing
@testable import WakaRouteKit

/// Captured verbatim from 正の数・負の数 / 両辺に同じ数をかける on 2026-08-10.
private let balanceFigure = """
<p>左の皿には x が3組。右の皿には 6 が3組。</p>
<svg viewBox="0 0 820 300" role="img" aria-labelledby="t-mul3 d-mul3">
<title id="t-mul3">1組ずつの天びんと3組ずつの天びん</title>
<desc id="d-mul3">左の図は左の皿にx、右の皿に6が1組ずつ乗ってつり合った天びん。右の図は両方の皿の中身を3組ずつにしたもの。</desc>
<text x="200" y="40" font-size="22">1組ずつ</text>
<line x1="130" y1="245" x2="270" y2="245" stroke="currentColor"/>
<polygon points="200,100 170,245 230,245" fill="none"/>
<text x="80" y="150">x</text>
<text x="320" y="150">6</text>
<text x="200" y="285">つり合っている</text>
</svg>
<p>右の図の左の皿は x が3つ。</p>
"""

@Suite("Figures in lesson bodies")
struct LessonFigureTests {

    @Test("A figure becomes its own block, not a paragraph of stray labels")
    func figureBecomesABlock() {
        let blocks = LessonContentParser.parse(balanceFigure)

        #expect(blocks.count == 3)
        #expect(blocks[1] == .figure(
            title: "1組ずつの天びんと3組ずつの天びん",
            description: "左の図は左の皿にx、右の皿に6が1組ずつ乗ってつり合った天びん。右の図は両方の皿の中身を3組ずつにしたもの。"
        ))
    }

    @Test("The labels drawn on the figure never reach the reader")
    func labelsAreNotProse() {
        let blocks = LessonContentParser.parse(balanceFigure)

        // 「1組ずつ」「つり合っている」 are words placed on the drawing. Run
        // together they were being shown as a sentence.
        for block in blocks {
            guard case let .paragraph(text) = block else { continue }
            #expect(!text.plain.contains("つり合っている"))
            #expect(!text.plain.contains("1組ずつ"))
        }
    }

    @Test("The prose either side of the figure survives, in order")
    func proseKeepsItsOrder() {
        let blocks = LessonContentParser.parse(balanceFigure)

        guard case let .paragraph(before) = blocks.first,
              case let .paragraph(after) = blocks.last else {
            Issue.record("expected prose either side of the figure, got \(blocks)")
            return
        }
        #expect(before.plain == "左の皿には x が3組。右の皿には 6 が3組。")
        #expect(after.plain == "右の図の左の皿は x が3つ。")
    }

    @Test("A figure nested inside a sentence is lifted out of it")
    func figureInsideAParagraphIsLifted() {
        let html = """
        <p>次の図を見てください。<svg role="img"><title>天びん</title>\
        <desc>つり合った天びん。</desc><text>x</text></svg></p>
        """
        let blocks = LessonContentParser.parse(html)

        #expect(blocks == [
            .paragraph(InlineText(runs: [InlineRun(text: "次の図を見てください。")])),
            .figure(title: "天びん", description: "つり合った天びん。")
        ])
    }

    @Test("A figure with neither title nor description is dropped, not shown empty")
    func emptyFigureIsDropped() {
        let blocks = LessonContentParser.parse("<svg><line x1=\"0\"/><text>x</text></svg>")
        #expect(blocks.isEmpty)
    }

    @Test("A figure inside a revealed answer still reads as a figure")
    func figureInsideDisclosure() {
        let html = """
        <details><summary>答えを見る</summary>\
        <svg role="img"><title>数直線</title><desc>0を中心にした数直線。</desc>\
        <text>0</text></svg></details>
        """
        let blocks = LessonContentParser.parse(html)

        guard case let .disclosure(_, inner) = blocks.first else {
            Issue.record("expected a disclosure, got \(blocks)")
            return
        }
        #expect(inner == [.figure(title: "数直線", description: "0を中心にした数直線。")])
    }
}
