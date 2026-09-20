import SwiftUI
import UIKit
import WakaRouteKit

/// Draws the formulas that lesson bodies carry.
///
/// Most of the maths in the content is only characters, and those stay inside
/// the sentence's own `Text` so that Japanese line breaking and Dynamic Type
/// keep working. Only `\dfrac` and `\sqrt` need stacked layout, and those are
/// drawn here.
struct MathFormulaView: View {
    let nodes: [MathNode]
    let font: UIFont

    var body: some View {
        // A formula is measured, never squeezed. Without this the renderer
        // offers the row a narrower width and the text truncates to an ellipsis
        // inside the drawing.
        MathRow(nodes: nodes, font: font).fixedSize()
    }
}

/// Shared measurements, all derived from the surrounding text's font so a
/// formula grows with the rest of the lesson.
enum MathRendering {
    /// The line a fraction bar sits on. Typographically the maths axis is half
    /// the x-height, which is also where a minus sign is drawn.
    static func axisHeight(for font: UIFont) -> CGFloat { font.xHeight / 2 }

    static func partFont(for font: UIFont) -> UIFont { font.withSize(font.pointSize * 0.85) }
    static func gap(for font: UIFont) -> CGFloat { font.pointSize * 0.10 }
    static func barThickness(for font: UIFont) -> CGFloat { max(1, font.pointSize * 0.055) }
    static func barOverhang(for font: UIFont) -> CGFloat { font.pointSize * 0.10 }
}

private extension VerticalAlignment {
    /// Everything in a formula lines up on the maths axis, not the baseline —
    /// otherwise a fraction sits on the text like a box rather than reading as
    /// part of the same expression.
    enum MathAxis: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat {
            context[.firstTextBaseline]
        }
    }

    static let mathAxis = VerticalAlignment(MathAxis.self)
}

// MARK: - Pieces

private struct MathRow: View {
    let nodes: [MathNode]
    let font: UIFont

    var body: some View {
        HStack(alignment: .mathAxis, spacing: 0) {
            ForEach(Array(nodes.enumerated()), id: \.offset) { _, node in
                MathNodeView(node: node, font: font)
            }
        }
    }
}

private struct MathNodeView: View {
    let node: MathNode
    let font: UIFont

    var body: some View {
        switch node {
        case let .text(value):
            MathText.text(value, font: font)
                .alignmentGuide(.mathAxis) { $0[.firstTextBaseline] - MathRendering.axisHeight(for: font) }

        case let .fraction(numerator, denominator):
            FractionView(numerator: numerator, denominator: denominator, font: font)

        case let .power(base, exponent):
            PowerView(base: base, exponent: exponent, font: font)

        case let .root(content):
            SquareRootView(content: content, font: font)

        case let .bracketed(open, close, content):
            BracketedView(open: open, close: close, content: content, font: font)

        case .space:
            Text(" ")
                .font(Font(font))
                .alignmentGuide(.mathAxis) { $0[.firstTextBaseline] - MathRendering.axisHeight(for: font) }
        }
    }
}

private struct FractionView: View {
    let numerator: [MathNode]
    let denominator: [MathNode]
    let font: UIFont

    var body: some View {
        let overhang = MathRendering.barOverhang(for: font)
        let partFont = MathRendering.partFont(for: font)

        VStack(spacing: MathRendering.gap(for: font)) {
            MathRow(nodes: numerator, font: partFont).padding(.horizontal, overhang)
            Rectangle().frame(height: MathRendering.barThickness(for: font))
            MathRow(nodes: denominator, font: partFont).padding(.horizontal, overhang)
        }
        // The two halves are the same height, so the bar sits at the middle.
        .alignmentGuide(.mathAxis) { $0.height / 2 }
        .padding(.horizontal, font.pointSize * 0.06)
    }
}

private struct PowerView: View {
    let base: [MathNode]
    let exponent: [MathNode]
    let font: UIFont

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            MathRow(nodes: base, font: font)
            MathRow(nodes: exponent, font: font.withSize(font.pointSize * 0.72))
                .alignmentGuide(.firstTextBaseline) { $0[.firstTextBaseline] + font.pointSize * 0.40 }
        }
        .alignmentGuide(.mathAxis) { $0[.firstTextBaseline] - MathRendering.axisHeight(for: font) }
    }
}

private struct SquareRootView: View {
    let content: [MathNode]
    let font: UIFont

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("√").font(Font(font))
            MathRow(nodes: content, font: font)
                .padding(.horizontal, 1)
                .overlay(alignment: .top) {
                    Rectangle()
                        .frame(height: MathRendering.barThickness(for: font))
                        .offset(y: -MathRendering.barThickness(for: font))
                }
        }
        .alignmentGuide(.mathAxis) { $0[.firstTextBaseline] - MathRendering.axisHeight(for: font) }
    }
}

private struct BracketedView: View {
    let open: String
    let close: String
    let content: [MathNode]
    let font: UIFont

    /// Brackets grow to hold what is inside them — a fraction needs taller ones
    /// than a number does.
    private var bracketFont: UIFont {
        content.needsLayout ? font.withSize(font.pointSize * 1.9) : font
    }

    var body: some View {
        HStack(alignment: .mathAxis, spacing: 0) {
            bracket(open)
            MathRow(nodes: content, font: font)
            bracket(close)
        }
    }

    @ViewBuilder
    private func bracket(_ symbol: String) -> some View {
        if symbol.isEmpty {
            EmptyView()
        } else {
            Text(symbol)
                .font(Font(bracketFont))
                .alignmentGuide(.mathAxis) { $0.height / 2 }
        }
    }
}

// MARK: - Text inside a formula

enum MathText {
    /// Variables are set in italics and numbers upright, the convention every
    /// textbook uses and the one the web already follows.
    static func text(_ value: String, font: UIFont) -> Text {
        value.reduce(Text("")) { partial, character in
            // A hyphen is not a minus sign: it is drawn shorter and sits lower.
            let glyph = character == "-" ? "−" : String(character)
            var piece = Text(glyph).font(Font(font))
            if character.isASCII, character.isLetter { piece = piece.italic() }
            return partial + piece
        }
    }

    /// A whole formula written as `Text`, for the ones that need no stacking.
    static func text(_ nodes: [MathNode], font: UIFont) -> Text {
        nodes.reduce(Text("")) { partial, node in
            switch node {
            case let .text(value):
                return partial + text(value, font: font)
            case let .power(base, exponent):
                return partial + text(base, font: font)
                    + text(exponent, font: font.withSize(font.pointSize * 0.72))
                        .baselineOffset(font.pointSize * 0.34)
            case let .bracketed(open, close, content):
                return partial + text(open, font: font) + text(content, font: font)
                    + text(close, font: font)
            case .space:
                return partial + Text(" ").font(Font(font))
            case .fraction, .root:
                // Handled by MathFormulaView; written out rather than dropped.
                return partial + text([node].plain, font: font)
            }
        }
    }
}

// MARK: - Formulas inside a sentence

/// Renders a stacked formula to an image so it can sit inside the sentence's
/// own `Text`.
///
/// `Text` cannot hold a fraction, and breaking the paragraph into separate
/// views to make room would take Japanese line breaking and 禁則処理 with it.
/// An image keeps the sentence a single `Text`; VoiceOver reads the spoken
/// form that the paragraph carries instead.
@MainActor
final class MathImageCache {
    static let shared = MathImageCache()

    struct Rendering {
        let image: Image
        /// How far below the text baseline the image has to drop for its
        /// fraction bar to land on the maths axis.
        let descent: CGFloat
    }

    private struct Key: Hashable {
        let nodes: [MathNode]
        let pointSize: CGFloat
        let scale: CGFloat
    }

    private var renderings: [Key: Rendering] = [:]
    /// Roughly a lesson's worth of formulas at a handful of text sizes. Reading
    /// for an hour should not leave every formula ever drawn in memory.
    private static let limit = 512

    func rendering(of nodes: [MathNode], font: UIFont, scale: CGFloat) -> Rendering? {
        let key = Key(nodes: nodes, pointSize: font.pointSize, scale: scale)
        if let cached = renderings[key] { return cached }
        if renderings.count >= Self.limit { renderings.removeAll(keepingCapacity: true) }

        // Drawn in one flat colour and used as a template, so the formula takes
        // the text colour it lands in and follows light and dark.
        let renderer = ImageRenderer(
            content: MathFormulaView(nodes: nodes, font: font).foregroundStyle(.black)
        )
        renderer.scale = scale
        guard let drawn = renderer.uiImage else { return nil }

        let rendering = Rendering(
            image: Image(uiImage: drawn.withRenderingMode(.alwaysTemplate)),
            descent: drawn.size.height / 2 - MathRendering.axisHeight(for: font)
        )
        renderings[key] = rendering
        return rendering
    }
}
