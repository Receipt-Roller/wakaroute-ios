import SwiftUI
import WakaRouteKit

/// Renders a parsed lesson body with native typography.
///
/// Every size comes from the system text styles, so the whole lesson scales
/// with the student's Dynamic Type setting — 開発ガイド §8. Nothing here uses a
/// fixed point size except the monospaced diagrams, which must not reflow.
struct LessonBodyView: View {
    let blocks: [LessonBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(blocks) { block in
                BlockView(block: block)
            }
        }
    }
}

private struct BlockView: View {
    let block: LessonBlock

    var body: some View {
        switch block {
        case let .heading(level, text):
            HeadingView(level: level, text: text)

        case let .paragraph(text):
            InlineTextView(text: text)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

        case let .bulletList(items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    ListItemRow(marker: "・", text: item)
                }
            }

        case let .numberedList(items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    ListItemRow(marker: "\(index + 1).", text: item)
                }
            }

        case let .code(text):
            CodeBlockView(text: text)

        case let .quote(inner):
            QuoteView(blocks: inner)

        case let .table(headers, rows):
            LessonTableView(headers: headers, rows: rows)

        case .divider:
            Divider().padding(.vertical, 2)

        case let .disclosure(summary, inner):
            DisclosureBlockView(summary: summary, blocks: inner)

        case let .figure(title, description):
            FigureView(title: title, description: description)
        }
    }
}

// MARK: - Text

/// Builds one `Text` from styled runs, so a bold phrase stays inside its
/// sentence and wraps with it — and so does a formula.
private struct InlineTextView: View {
    let text: InlineText
    var textStyle: UIFont.TextStyle = .body

    @Environment(\.displayScale) private var displayScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if text.hasMath {
            // One label for the whole sentence: a stacked fraction is drawn, and
            // a drawing says nothing. `spoken` reads 「2ぶんのx」 where the
            // characters alone would say "x 2".
            composed.accessibilityLabel(text.spoken)
        } else {
            composed
        }
    }

    private var composed: Text {
        let font = UIFont.preferredFont(
            forTextStyle: textStyle,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: dynamicTypeSize.contentSizeCategory)
        )
        return text.runs.reduce(Text("")) { $0 + piece(for: $1, font: font) }
    }

    private func piece(for run: InlineRun, font: UIFont) -> Text {
        guard let math = run.math else {
            var piece = Text(run.text)
            if run.isCode { piece = piece.font(.system(.body, design: .monospaced)) }
            if run.isBold { piece = piece.bold() }
            if run.isItalic { piece = piece.italic() }
            return piece
        }

        guard math.needsLayout,
              let drawn = MathImageCache.shared.rendering(of: math, font: font, scale: displayScale)
        else {
            return MathText.text(math, font: font)
        }

        return Text(drawn.image).baselineOffset(-drawn.descent)
    }
}

private extension DynamicTypeSize {
    /// UIKit needs the size as a content size category to resolve a font, and
    /// there is no conversion in either framework.
    var contentSizeCategory: UIContentSizeCategory {
        switch self {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        case .accessibility5: .accessibilityExtraExtraExtraLarge
        @unknown default: .large
        }
    }
}

private struct HeadingView: View {
    let level: Int
    let text: InlineText

    private var font: Font {
        switch level {
        case 1: .title2.weight(.bold)
        case 2: .title3.weight(.semibold)
        default: .headline
        }
    }

    /// A formula in a heading has to be drawn at the heading's size.
    private var textStyle: UIFont.TextStyle {
        switch level {
        case 1: .title2
        case 2: .title3
        default: .headline
        }
    }

    var body: some View {
        InlineTextView(text: text, textStyle: textStyle)
            .font(font)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, level <= 2 ? 6 : 2)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct ListItemRow: View {
    let marker: String
    let text: InlineText

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker)
                .font(.body)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            InlineTextView(text: text)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Blocks

/// ASCII diagrams — a thermometer, building floors — that only line up in a
/// monospaced font. Scrolls horizontally rather than wrapping, because a
/// wrapped diagram is worse than one the student has to nudge sideways.
private struct CodeBlockView: View {
    let text: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .lineSpacing(2)
                .padding(12)
                .fixedSize(horizontal: true, vertical: false)
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel("図: \(text.replacingOccurrences(of: "\n", with: "、"))")
    }
}

private struct QuoteView: View {
    let blocks: [LessonBlock]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(.tint)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(blocks) { BlockView(block: $0) }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Scrolls horizontally rather than squeezing columns, so a four-column table
/// stays readable at large text sizes.
private struct LessonTableView: View {
    let headers: [InlineText]
    let rows: [[InlineText]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                if !headers.isEmpty {
                    row(headers, isHeader: true)
                    Divider()
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { index, cells in
                    row(cells, isHeader: false)
                    if index < rows.count - 1 { Divider() }
                }
            }
            .padding(12)
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func row(_ cells: [InlineText], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                InlineTextView(text: cell, textStyle: .subheadline)
                    .font(isHeader ? .subheadline.weight(.semibold) : .subheadline)
                    .foregroundStyle(isHeader ? .secondary : .primary)
                    .frame(minWidth: 64, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }
}

/// A diagram the app does not draw.
///
/// Lesson figures are inline SVG. Rather than flatten the labels positioned on
/// the drawing into a line — which reads as nonsense — this shows the author's
/// own description, written for exactly this purpose and used by the web for
/// the same reason.
private struct FigureView: View {
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "photo")
                .font(.subheadline)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                if !title.isEmpty {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("図: \(title)。\(description)")
    }
}

/// 「答えを確認する」 — collapsed until the student chooses to look.
///
/// This is the whole point of parsing rather than importing HTML: an expanded
/// answer removes the exercise.
private struct DisclosureBlockView: View {
    let summary: String
    let blocks: [LessonBlock]

    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                // The only other animation in the app is the progress ring, and
                // it already checks this. A setting the student turned on has to
                // hold everywhere, not in most places.
                if reduceMotion {
                    isExpanded.toggle()
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                    Text(summary).font(.subheadline.weight(.medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(summary)
            .accessibilityHint(isExpanded ? "閉じる" : "ひらいて答えを見る")

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(blocks) { BlockView(block: $0) }
                }
                .padding(.leading, 4)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}
