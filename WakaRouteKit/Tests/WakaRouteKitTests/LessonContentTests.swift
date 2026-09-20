import Foundation
import Testing
@testable import WakaRouteKit

/// Captured verbatim from 数と式 / 正の数・負の数 / 0より小さい数はどこにある？
/// on 2026-08-03. Real content, not a hand-written sample.
private let liveBody = """
<h1 id="section">0より小さい数はどこにある？</h1>
<h2 id="section-1">このレッスンのゴール</h2>
<ul>
<li>0より小さい数が、どんな場面で使われるか説明できる</li>
<li>「マイナス3」を <strong>−3</strong> と書ける</li>
</ul>
<hr />
<h2 id="section-2">冬の朝、気温は何度？</h2>
<p>天気予報で「朝の気温は <strong>氷点下3度</strong> です」と聞いたことはありませんか。</p>
<h3 id="section-3">温度計で見てみよう</h3>
<pre><code class="language-text">  3℃  ─  0より上
  0℃  ┼  水がこおり始める基準
 −3℃  ●  氷点下3度
</code></pre>
<blockquote>
<p><strong>ポイント</strong><br />
<strong>−（マイナス）</strong> は「0より小さい側にある」ことを表す符号です。</p>
</blockquote>
<table>
<thead>
<tr><th>場面</th><th>基準</th><th>0より下</th></tr>
</thead>
<tbody>
<tr><td>気温</td><td>0℃</td><td>−3℃</td></tr>
<tr><td>建物</td><td>入口</td><td>−2階</td></tr>
</tbody>
</table>
<h2 id="section-5">やってみよう</h2>
<ol>
<li>0℃より5℃低い気温</li>
<li>海面より12m低い場所</li>
</ol>
<details>
<summary>答えを確認する</summary>
<ol>
<li><strong>−5℃</strong></li>
<li><strong>−12m</strong></li>
</ol>
</details>
"""

@Suite("Lesson content parsing")
struct LessonContentTests {

    private var blocks: [LessonBlock] { LessonContentParser.parse(liveBody) }

    @Test("Parses the real lesson body into the expected block sequence")
    func parsesLiveBody() {
        let kinds = blocks.map { block -> String in
            switch block {
            case .heading(let level, _): "h\(level)"
            case .paragraph: "p"
            case .bulletList: "ul"
            case .numberedList: "ol"
            case .code: "pre"
            case .quote: "quote"
            case .table: "table"
            case .divider: "hr"
            case .disclosure: "details"
            case .figure: "figure"
            }
        }

        #expect(kinds == ["h1", "h2", "ul", "hr", "h2", "p", "h3", "pre", "quote", "table", "h2", "ol", "details"])
    }

    /// The answers to 「やってみよう」 must stay hidden until the student asks.
    /// `NSAttributedString`'s HTML import renders `<details>` expanded, which
    /// hands over the answer before they have tried the exercise.
    @Test("details becomes a collapsed disclosure, not inline content")
    func detailsIsCollapsible() throws {
        guard case let .disclosure(summary, inner) = try #require(blocks.last) else {
            Issue.record("Expected a disclosure block"); return
        }

        #expect(summary == "答えを確認する")
        #expect(inner.count == 1)
        if case let .numberedList(items) = inner[0] {
            #expect(items.map(\.plain) == ["−5℃", "−12m"])
        } else {
            Issue.record("Expected the answers as a numbered list")
        }
    }

    /// The thermometer diagram only reads correctly in a monospaced font, and
    /// its leading spaces and line breaks must survive intact.
    @Test("Preformatted blocks keep their exact whitespace and newlines")
    func codeBlockPreservesLayout() throws {
        guard case let .code(text) = try #require(blocks.first(where: {
            if case .code = $0 { return true } else { return false }
        })) else { return }

        let lines = text.components(separatedBy: "\n")
        #expect(lines.count == 3)
        #expect(lines[0] == "  3℃  ─  0より上", "Leading spaces align the diagram.")
        #expect(lines[2].hasPrefix(" −3℃"))
    }

    @Test("Bold survives inside paragraphs, with surrounding text intact")
    func inlineBold() throws {
        guard case let .paragraph(text) = try #require(blocks.first(where: {
            if case let .paragraph(t) = $0 { return t.plain.contains("氷点下") } else { return false }
        })) else { return }

        #expect(text.runs.contains { $0.isBold && $0.text.contains("氷点下3度") })
        #expect(text.plain.hasPrefix("天気予報で"))
        #expect(text.plain.hasSuffix("聞いたことはありませんか。"))
    }

    @Test("Tables keep headers and rows")
    func parsesTable() throws {
        guard case let .table(headers, rows) = try #require(blocks.first(where: {
            if case .table = $0 { return true } else { return false }
        })) else { return }

        #expect(headers.map(\.plain) == ["場面", "基準", "0より下"])
        #expect(rows.count == 2)
        #expect(rows[0].map(\.plain) == ["気温", "0℃", "−3℃"])
    }

    @Test("A line break inside a quote becomes a newline, not a lost space")
    func brBecomesNewline() throws {
        guard case let .quote(inner) = try #require(blocks.first(where: {
            if case .quote = $0 { return true } else { return false }
        })) else { return }

        let text = inner.compactMap { block -> InlineText? in
            if case let .paragraph(t) = block { return t } else { return nil }
        }.first

        #expect(try #require(text).plain.contains("\n"))
    }

    @Test("Whitespace between tags does not become empty paragraphs")
    func noBlankParagraphs() {
        for block in blocks {
            if case let .paragraph(text) = block {
                #expect(!text.isEmpty)
            }
        }
    }

    @Test("Entities are decoded")
    func decodesEntities() {
        let parsed = LessonContentParser.parse("<p>a &lt; b &amp;&amp; c &gt; d</p>")
        guard case let .paragraph(text) = parsed[0] else { Issue.record("expected paragraph"); return }
        #expect(text.plain == "a < b && c > d")
    }

    @Test("Empty or malformed input yields no blocks rather than crashing")
    func handlesBadInput() {
        #expect(LessonContentParser.parse("").isEmpty)
        #expect(LessonContentParser.parse("   ").isEmpty)
        // Unclosed tags must not hang or drop the remaining content.
        let parsed = LessonContentParser.parse("<p>おわりのタグがない")
        #expect(parsed.count == 1)
    }

    @Test("Plain text with no tags still renders")
    func plainTextSurvives() {
        let parsed = LessonContentParser.parse("タグのない本文")
        #expect(parsed.count == 1)
        if case let .paragraph(text) = parsed[0] {
            #expect(text.plain == "タグのない本文")
        } else {
            Issue.record("Expected a paragraph")
        }
    }
}
