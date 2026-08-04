import SwiftUI

/// Caps how wide content grows, and centres it.
///
/// On an iPad a full-width paragraph runs past 2,000 points. Long lines are
/// hard to read because the eye loses the start of the next one on the way
/// back — the usual guidance is roughly 45–75 characters, and Japanese text is
/// no different. This app is mostly reading, so the cap matters more here than
/// in a typical utility.
///
/// SwiftUI has no equivalent of UIKit's `readableContentGuide`, so the width is
/// set explicitly. iPhone layouts are always narrower than the cap and are
/// therefore untouched.
struct ReadableWidth: ViewModifier {
    /// Comfortable for a paragraph at the default text size. Deliberately not
    /// scaled with Dynamic Type: larger text means fewer characters per line,
    /// which is already the effect we want.
    static let maximum: CGFloat = 720

    /// For a screen laid out in two columns rather than one paragraph.
    ///
    /// The cap exists to keep a *line of text* short. Once the content is two
    /// columns each is already narrow, and holding the pair to 720 would waste
    /// the width the columns were added to use.
    static let wide: CGFloat = 1100

    var limit: CGFloat = ReadableWidth.maximum

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: limit)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

extension View {
    /// Keeps a line of text to a comfortable length on wide screens.
    func readableWidth(_ limit: CGFloat = ReadableWidth.maximum) -> some View {
        modifier(ReadableWidth(limit: limit))
    }
}
