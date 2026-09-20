import Foundation
import Testing
@testable import WakaRouteKit

/// Every expression here is copied from a published lesson body.
@Suite("Formulas in lesson bodies")
struct MathExpressionTests {

    // MARK: - Finding formulas

    @Test("A formula is lifted out of the sentence around it")
    func splitsProseAndFormula() {
        let segments = MathExpressionParser.segments(
            in: "約分して \\(x = \\dfrac{3}{2}\\) が答えです。"
        )

        #expect(segments == [
            .prose("約分して "),
            .formula("x = \\dfrac{3}{2}"),
            .prose(" が答えです。")
        ])
    }

    @Test("Several formulas in one sentence each come out separately")
    func splitsRepeatedFormulas() {
        let segments = MathExpressionParser.segments(
            in: "\\(x \\div 3\\) は \\(\\dfrac{x}{3}\\)"
        )

        #expect(segments.count == 3)
        #expect(segments.first == .formula("x \\div 3"))
        #expect(segments.last == .formula("\\dfrac{x}{3}"))
    }

    @Test("Text with no formula is left alone")
    func leavesProseUntouched() {
        #expect(MathExpressionParser.segments(in: "0より小さい数") == [.prose("0より小さい数")])
    }

    @Test("An unclosed delimiter stays prose rather than eating the sentence")
    func unclosedDelimiterStaysProse() {
        let segments = MathExpressionParser.segments(in: "式は \\(x = 5 で終わりです。")
        #expect(segments == [.prose("式は \\(x = 5 で終わりです。")])
    }

    // MARK: - Parsing

    @Test("The 84% case: a formula that is only characters")
    func parsesPlainCharacters() {
        #expect(MathExpressionParser.parse("x = 5") == [.text("x = 5")])
    }

    @Test("Operators become the characters students read")
    func parsesOperators() {
        #expect(MathExpressionParser.parse("6 \\div 4") == [.text("6 ÷ 4")])
        #expect(MathExpressionParser.parse("x \\times 3") == [.text("x × 3")])
        #expect(MathExpressionParser.parse("a \\neq b") == [.text("a ≠ b")])
    }

    @Test("A fraction keeps its two halves apart")
    func parsesFraction() {
        #expect(MathExpressionParser.parse("\\dfrac{x}{2}") == [
            .fraction(numerator: [.text("x")], denominator: [.text("2")])
        ])
    }

    @Test("A fraction inside a longer expression")
    func parsesFractionInContext() {
        #expect(MathExpressionParser.parse("x = \\dfrac{3}{2}") == [
            .text("x = "),
            .fraction(numerator: [.text("3")], denominator: [.text("2")])
        ])
    }

    @Test("Sized brackets hold their contents")
    func parsesSizedBrackets() {
        let parsed = MathExpressionParser.parse("\\left( \\dfrac{5}{4} + 1 \\right)")

        #expect(parsed == [
            .bracketed(open: "(", close: ")", body: [
                .fraction(numerator: [.text("5")], denominator: [.text("4")]),
                .text(" + 1")
            ])
        ])
    }

    @Test("A power raises only the character before it")
    func raisesOnlyTheBase() {
        #expect(MathExpressionParser.parse("3x^2") == [
            .text("3"),
            .power(base: [.text("x")], exponent: [.text("2")])
        ])
    }

    @Test("A braced exponent is read whole")
    func parsesBracedExponent() {
        #expect(MathExpressionParser.parse("x^{10}") == [
            .power(base: [.text("x")], exponent: [.text("10")])
        ])
    }

    @Test("A square root, for the 平方根 lessons still to come")
    func parsesRoot() {
        #expect(MathExpressionParser.parse("\\sqrt{2}") == [.root([.text("2")])])
    }

    @Test("An unknown command stays visible instead of vanishing")
    func keepsUnknownCommand() {
        #expect(MathExpressionParser.parse("\\wobble").plain == "\\wobble")
    }

    @Test("The longest expression in the content parses")
    func parsesLongestExpression() {
        let latex = "6 \\times \\left( \\dfrac{5}{4} + 1 \\right) - 2 \\times "
            + "\\left( \\dfrac{5}{4} - 2 \\right)"
        let parsed = MathExpressionParser.parse(latex)

        #expect(parsed.plain == "6 × (5/4 + 1) - 2 × (5/4 - 2)")
        #expect(parsed.needsLayout)
    }

    // MARK: - Written form

    @Test("Only a formula needing stacked layout says so")
    func reportsWhatNeedsLayout() {
        #expect(MathExpressionParser.parse("x = 5").needsLayout == false)
        #expect(MathExpressionParser.parse("6 \\div 4").needsLayout == false)
        #expect(MathExpressionParser.parse("\\dfrac{x}{2}").needsLayout)
        #expect(MathExpressionParser.parse("\\sqrt{2}").needsLayout)
    }

    @Test("The one-line fallback brackets a part only when it needs it")
    func writesFallbackOnOneLine() {
        #expect(MathExpressionParser.parse("\\dfrac{x}{3}").plain == "x/3")
        #expect(MathExpressionParser.parse("\\dfrac{x+1}{3}").plain == "(x+1)/3")
    }

    // MARK: - Spoken form

    @Test("A fraction reads denominator first, the way it is said in Japanese")
    func speaksFraction() {
        #expect(MathExpressionParser.parse("\\dfrac{x}{2}").spoken == "2ぶんのx")
    }

    @Test("Operators are read as words")
    func speaksOperators() {
        #expect(MathExpressionParser.parse("x = 5").spoken == "x イコール 5")
        #expect(MathExpressionParser.parse("6 \\times 4").spoken == "6 かける 4")
    }

    @Test("A leading minus is a sign; a minus between terms is a subtraction")
    func speaksMinusByItsRole() {
        #expect(MathExpressionParser.parse("-3").spoken == "マイナス 3")
        #expect(MathExpressionParser.parse("x - 3").spoken == "x ひく 3")
        #expect(MathExpressionParser.parse("6 - (-2)").spoken
            == "6 ひく かっこ マイナス 2 かっことじ")
    }

    @Test("A power is read as 乗")
    func speaksPower() {
        #expect(MathExpressionParser.parse("x^2").spoken == "xの2乗")
    }

    @Test("Digits of a number stay together")
    func speaksMultiDigitNumbers() {
        #expect(MathExpressionParser.parse("\\dfrac{55}{12}").spoken == "12ぶんの55")
    }

    // MARK: - Through the lesson parser

    @Test("A lesson sentence carries its formula as a formula")
    func parsesFormulaInsideLessonHTML() {
        let html = "<li><span class=\"math\">\\(\\dfrac{x}{a} = b\\)</span> の形の方程式</li>"
        let blocks = LessonContentParser.parse("<ul>\(html)</ul>")

        guard case let .bulletList(items) = blocks.first, let item = items.first else {
            Issue.record("expected a bullet list, got \(blocks)")
            return
        }

        #expect(item.hasMath)
        #expect(item.runs.first?.math == [
            .fraction(numerator: [.text("x")], denominator: [.text("a")]),
            .text(" = b")
        ])
        #expect(item.runs.last?.text == " の形の方程式")
        #expect(item.spoken == "aぶんのx イコール b の形の方程式")
    }

    @Test("Prose around the formula keeps its emphasis")
    func keepsEmphasisAroundFormula() {
        let blocks = LessonContentParser.parse(
            "<p><strong>答え</strong>は \\(x = 5\\) です。</p>"
        )

        guard case let .paragraph(text) = blocks.first else {
            Issue.record("expected a paragraph, got \(blocks)")
            return
        }

        #expect(text.runs.first?.isBold == true)
        #expect(text.runs.contains { $0.math != nil })
        #expect(text.plain == "答えは x = 5 です。")
    }

    @Test("A formula inside a code block is left as written")
    func leavesCodeBlocksAlone() {
        let blocks = LessonContentParser.parse("<pre><code>\\(x\\)</code></pre>")
        #expect(blocks == [.code("\\(x\\)")])
    }
}
