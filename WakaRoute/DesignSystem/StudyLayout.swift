import SwiftUI

/// Where the app decides it has room to do two things at once.
///
/// Deliberately a **width, not a device**. Split View, Slide Over and Stage
/// Manager all hand an iPad app an arbitrary width, and a check for "is this an
/// iPad" would put two 300pt columns on screen the moment a student pulls
/// another app alongside. The question is never what the student is holding —
/// it is how much room this window has right now.
enum StudyLayout {

    /// Enough to read a lesson and answer its quiz at the same time.
    ///
    /// Below this the two columns are each narrower than an iPhone, which is
    /// worse than the sheet it replaces. An 11-inch iPad clears it in landscape
    /// and not in portrait, which is the right answer for both.
    static let sideBySide: CGFloat = 900
}
