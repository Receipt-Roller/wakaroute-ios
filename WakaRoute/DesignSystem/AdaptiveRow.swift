import SwiftUI

/// A row that becomes a column once the text is large enough that a row stops
/// working.
///
/// Icon-text-chevron rows are the standard shape of this app, and at the
/// accessibility text sizes they fail badly: the icon and the chevron keep
/// their width, the label is squeezed into whatever is left, and Japanese
/// wraps to one or two characters a line. 開発ガイド §8 asks for the largest
/// sizes to be usable, not merely to render.
///
/// Apple's own answer is to swap the layout rather than the view, so state and
/// identity survive the change.
struct AdaptiveRow<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var spacing: CGFloat = 14
    var alignment: VerticalAlignment = .center
    @ViewBuilder var content: () -> Content

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
            : AnyLayout(HStackLayout(alignment: alignment, spacing: spacing))

        layout { content() }
    }
}

/// The disclosure arrow, hidden once the row has become a column.
///
/// Stacked under the text it reads as content rather than as an affordance, and
/// it says nothing a pushed row does not already announce — it is
/// `accessibilityHidden` in either case.
struct RowChevron: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if !dynamicTypeSize.isAccessibilitySize {
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }
}
