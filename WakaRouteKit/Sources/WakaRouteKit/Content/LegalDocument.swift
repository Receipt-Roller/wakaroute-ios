import Foundation

/// The service's own documents, shipped inside the app.
///
/// They used to be links into Safari. A 中学生 who taps 利用規約 should not be
/// handed to a browser and left to find their way back — and with no signal,
/// they could not read them at all. These are the documents a student is
/// entitled to read before agreeing to anything, so they are always available.
///
/// Bundled rather than fetched: the text is then guaranteed present at review
/// time and offline. The cost is that changing a word needs an app release,
/// which is a trade worth making only because forced updates reach everyone
/// (t-1fa7241).
public enum LegalDocument: String, CaseIterable, Sendable, Identifiable {
    case about = "legal-about"
    case forParents = "legal-for-parents"
    case terms = "legal-terms"
    case privacy = "legal-privacy"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .about: "ワカルートとは"
        case .forParents: "保護者の方へ"
        case .terms: "利用規約"
        case .privacy: "プライバシーポリシー"
        }
    }

    public var symbolName: String {
        switch self {
        case .about: "info.circle"
        case .forParents: "person.2"
        case .terms: "doc.text"
        case .privacy: "hand.raised"
        }
    }

    /// The raw HTML, or nil if the resource is missing from the bundle.
    public func html() -> String? {
        guard let url = Bundle.module.url(forResource: rawValue, withExtension: "html") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Ready to render, using the same parser and typography as a lesson.
    public func blocks() -> [LessonBlock] {
        html().map(LessonContentParser.parse) ?? []
    }

    /// Text still waiting on a decision, written as 【…】.
    ///
    /// A placeholder reaching a student would be worse than an incomplete
    /// document: 【運営者名】 in a published privacy policy is a legal document
    /// that names nobody. `LegalDocumentTests` fails while any remain, so this
    /// cannot ship by being forgotten.
    public func placeholders() -> [String] {
        guard let html = html() else { return [] }
        var found: [String] = []
        var remainder = Substring(html)

        while let open = remainder.firstIndex(of: "【"),
              let close = remainder[open...].firstIndex(of: "】") {
            found.append(String(remainder[remainder.index(after: open)..<close]))
            remainder = remainder[remainder.index(after: close)...]
        }
        return found
    }
}
