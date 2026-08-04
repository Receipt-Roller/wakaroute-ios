import Foundation

/// A run of text with the emphasis the author gave it.
public struct InlineRun: Sendable, Equatable {
    public let text: String
    public let isBold: Bool
    public let isItalic: Bool
    public let isCode: Bool

    public init(text: String, isBold: Bool = false, isItalic: Bool = false, isCode: Bool = false) {
        self.text = text
        self.isBold = isBold
        self.isItalic = isItalic
        self.isCode = isCode
    }
}

public struct InlineText: Sendable, Equatable {
    public let runs: [InlineRun]

    public init(runs: [InlineRun]) {
        self.runs = runs
    }

    public var plain: String { runs.map(\.text).joined() }
    public var isEmpty: Bool { plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// One block of lesson content.
public indirect enum LessonBlock: Sendable, Equatable, Identifiable {
    case heading(level: Int, text: InlineText)
    case paragraph(InlineText)
    case bulletList([InlineText])
    case numberedList([InlineText])
    /// Preformatted. Must be rendered monospaced — lesson bodies use these for
    /// ASCII diagrams (a thermometer, building floors) that collapse in a
    /// proportional font.
    case code(String)
    case quote([LessonBlock])
    case table(headers: [InlineText], rows: [[InlineText]])
    case divider
    /// `<details>` — an exercise answer the student reveals deliberately.
    /// Rendering this expanded would hand them the answer before they try.
    case disclosure(summary: String, blocks: [LessonBlock])

    public var id: String {
        switch self {
        case let .heading(level, text): "h\(level):\(text.plain)"
        case let .paragraph(text): "p:\(text.plain.prefix(40))"
        case let .bulletList(items): "ul:\(items.first?.plain.prefix(30) ?? "")\(items.count)"
        case let .numberedList(items): "ol:\(items.first?.plain.prefix(30) ?? "")\(items.count)"
        case let .code(text): "pre:\(text.prefix(30))"
        case let .quote(blocks): "bq:\(blocks.first?.id ?? "")"
        case let .table(headers, rows): "tbl:\(headers.first?.plain ?? "")\(rows.count)"
        case .divider: "hr:\(UUID().uuidString)"
        case let .disclosure(summary, _): "det:\(summary)"
        }
    }
}

/// Parses the HTML that MANABU2 lesson bodies carry.
///
/// The bodies are generated from Markdown, so the tag set is small and regular:
/// `h1–h3, p, ul, ol, li, strong, em, code, pre, blockquote, br, hr, table,
/// thead, tbody, tr, th, td, details, summary`.
///
/// A parser rather than `NSAttributedString(documentType: .html)` because that
/// import produces serif text at a fixed size — ignoring Dynamic Type — renders
/// `<details>` already expanded, which gives away exercise answers, and loses
/// the monospacing that the ASCII diagrams depend on.
public enum LessonContentParser {

    public static func parse(_ html: String) -> [LessonBlock] {
        let nodes = HTMLNode.parse(html)
        return blocks(from: nodes)
    }

    static func blocks(from nodes: [HTMLNode]) -> [LessonBlock] {
        var result: [LessonBlock] = []

        for node in nodes {
            switch node {
            case let .text(value):
                // Whitespace between block tags. Loose text is rare but real.
                let inline = InlineText(runs: [InlineRun(text: value)])
                if !inline.isEmpty { result.append(.paragraph(inline)) }

            case let .element(name, children):
                switch name {
                case "h1", "h2", "h3", "h4", "h5", "h6":
                    let level = Int(name.dropFirst()) ?? 2
                    result.append(.heading(level: level, text: inline(children)))

                case "p":
                    let text = inline(children)
                    if !text.isEmpty { result.append(.paragraph(text)) }

                case "ul":
                    let items = listItems(children)
                    if !items.isEmpty { result.append(.bulletList(items)) }

                case "ol":
                    let items = listItems(children)
                    if !items.isEmpty { result.append(.numberedList(items)) }

                case "pre":
                    result.append(.code(preformattedText(children)))

                case "blockquote":
                    let inner = blocks(from: children)
                    if !inner.isEmpty { result.append(.quote(inner)) }

                case "hr":
                    result.append(.divider)

                case "table":
                    if let table = table(from: children) { result.append(table) }

                case "details":
                    let summary = children.compactMap { child -> String? in
                        guard case let .element(name, inner) = child, name == "summary" else { return nil }
                        return inline(inner).plain
                    }.first ?? "答えを見る"

                    let inner = blocks(from: children.filter {
                        if case let .element(name, _) = $0, name == "summary" { return false }
                        return true
                    })
                    result.append(.disclosure(summary: summary, blocks: inner))

                case "div", "section", "article", "body", "html", "main":
                    result += blocks(from: children)

                default:
                    // An unexpected element still contributes its text rather
                    // than silently dropping a paragraph of the lesson.
                    let text = inline([node])
                    if !text.isEmpty { result.append(.paragraph(text)) }
                }
            }
        }

        return result
    }

    private static func listItems(_ nodes: [HTMLNode]) -> [InlineText] {
        nodes.compactMap { node in
            guard case let .element(name, children) = node, name == "li" else { return nil }
            let text = inline(children)
            return text.isEmpty ? nil : text
        }
    }

    private static func table(from nodes: [HTMLNode]) -> LessonBlock? {
        var headers: [InlineText] = []
        var rows: [[InlineText]] = []

        func walk(_ nodes: [HTMLNode]) {
            for node in nodes {
                guard case let .element(name, children) = node else { continue }
                switch name {
                case "thead", "tbody", "tfoot":
                    walk(children)
                case "tr":
                    var cells: [InlineText] = []
                    var isHeaderRow = false
                    for cell in children {
                        guard case let .element(cellName, cellChildren) = cell else { continue }
                        if cellName == "th" { isHeaderRow = true }
                        if cellName == "th" || cellName == "td" {
                            cells.append(inline(cellChildren))
                        }
                    }
                    if isHeaderRow && headers.isEmpty {
                        headers = cells
                    } else if !cells.isEmpty {
                        rows.append(cells)
                    }
                default:
                    walk(children)
                }
            }
        }

        walk(nodes)
        guard !headers.isEmpty || !rows.isEmpty else { return nil }
        return .table(headers: headers, rows: rows)
    }

    private static func preformattedText(_ nodes: [HTMLNode]) -> String {
        var out = ""
        func walk(_ nodes: [HTMLNode]) {
            for node in nodes {
                switch node {
                case let .text(value): out += value
                case let .element(name, children):
                    if name == "br" { out += "\n" } else { walk(children) }
                }
            }
        }
        walk(nodes)
        // Generated code blocks carry a trailing newline from the fence.
        return out.trimmingCharacters(in: .newlines)
    }

    /// Flattens inline markup into runs.
    static func inline(_ nodes: [HTMLNode], bold: Bool = false, italic: Bool = false, code: Bool = false) -> InlineText {
        var runs: [InlineRun] = []

        for node in nodes {
            switch node {
            case let .text(value):
                guard !value.isEmpty else { continue }
                runs.append(InlineRun(text: value, isBold: bold, isItalic: italic, isCode: code))

            case let .element(name, children):
                switch name {
                case "strong", "b":
                    runs += inline(children, bold: true, italic: italic, code: code).runs
                case "em", "i":
                    runs += inline(children, bold: bold, italic: true, code: code).runs
                case "code":
                    runs += inline(children, bold: bold, italic: italic, code: true).runs
                case "br":
                    runs.append(InlineRun(text: "\n"))
                default:
                    runs += inline(children, bold: bold, italic: italic, code: code).runs
                }
            }
        }

        return InlineText(runs: collapse(runs))
    }

    /// Merges adjacent runs with identical styling, so a sentence split across
    /// tags does not render as separate pieces.
    private static func collapse(_ runs: [InlineRun]) -> [InlineRun] {
        var result: [InlineRun] = []
        for run in runs where !run.text.isEmpty {
            if let last = result.last,
               last.isBold == run.isBold, last.isItalic == run.isItalic, last.isCode == run.isCode {
                result[result.count - 1] = InlineRun(
                    text: last.text + run.text,
                    isBold: last.isBold, isItalic: last.isItalic, isCode: last.isCode
                )
            } else {
                result.append(run)
            }
        }
        return result
    }
}

/// A minimal HTML tree.
enum HTMLNode: Sendable, Equatable {
    case text(String)
    indirect case element(name: String, children: [HTMLNode])

    /// Tags that never have a closing partner.
    private static let voidElements: Set<String> = ["br", "hr", "img", "input", "meta", "link"]
    /// Inside these, markup is not interpreted and whitespace is preserved.
    ///
    /// `pre` is deliberately absent: bodies wrap code as `<pre><code>`, so
    /// treating `pre` as raw would capture the literal `<code …>` tag as the
    /// first line of the diagram. `code` alone gives the same protection in
    /// the right place.
    private static let rawTextElements: Set<String> = ["code", "script", "style"]

    static func parse(_ html: String) -> [HTMLNode] {
        var scanner = HTMLScanner(html: Array(html))
        return scanner.parseNodes(until: nil)
    }

    private struct HTMLScanner {
        let html: [Character]
        var index = 0

        init(html: [Character]) { self.html = html }

        var isAtEnd: Bool { index >= html.count }

        mutating func parseNodes(until closing: String?) -> [HTMLNode] {
            var nodes: [HTMLNode] = []

            while !isAtEnd {
                if html[index] == "<" {
                    if peekIsClosingTag() {
                        let name = readClosingTag()
                        // A stray close for an element we are not in is ignored
                        // rather than aborting the rest of the document.
                        if name == closing { return nodes }
                        continue
                    }

                    guard let (name, selfClosing) = readOpeningTag() else {
                        nodes.append(.text("<"))
                        index += 1
                        continue
                    }

                    if selfClosing || HTMLNode.voidElements.contains(name) {
                        nodes.append(.element(name: name, children: []))
                    } else if HTMLNode.rawTextElements.contains(name) {
                        let raw = readRawText(until: name)
                        nodes.append(.element(name: name, children: [.text(raw)]))
                    } else {
                        let children = parseNodes(until: name)
                        nodes.append(.element(name: name, children: children))
                    }
                } else {
                    let text = readText()
                    if !text.isEmpty { nodes.append(.text(text)) }
                }
            }

            return nodes
        }

        private func peekIsClosingTag() -> Bool {
            index + 1 < html.count && html[index + 1] == "/"
        }

        private mutating func readClosingTag() -> String {
            index += 2                        // consume "</"
            var name = ""
            while !isAtEnd, html[index] != ">" {
                name.append(html[index])
                index += 1
            }
            if !isAtEnd { index += 1 }        // consume ">"
            return name.trimmingCharacters(in: .whitespaces).lowercased()
        }

        private mutating func readOpeningTag() -> (name: String, selfClosing: Bool)? {
            let start = index
            index += 1                        // consume "<"

            var name = ""
            while !isAtEnd, html[index].isLetter || html[index].isNumber {
                name.append(html[index])
                index += 1
            }

            guard !name.isEmpty else {
                index = start
                return nil
            }

            // Skip attributes; none of them affect rendering here.
            var selfClosing = false
            var inQuote: Character?
            while !isAtEnd {
                let character = html[index]
                if let quote = inQuote {
                    if character == quote { inQuote = nil }
                } else if character == "\"" || character == "'" {
                    inQuote = character
                } else if character == "/" {
                    selfClosing = true
                } else if character == ">" {
                    index += 1
                    return (name.lowercased(), selfClosing)
                }
                index += 1
            }

            return (name.lowercased(), selfClosing)
        }

        /// Everything up to the matching close, uninterpreted.
        private mutating func readRawText(until name: String) -> String {
            var out = ""
            let closing = Array("</\(name)")

            while !isAtEnd {
                if html[index] == "<", matches(closing) {
                    _ = readClosingTag()
                    break
                }
                out.append(html[index])
                index += 1
            }

            return HTMLNode.decodeEntities(out)
        }

        private func matches(_ pattern: [Character]) -> Bool {
            guard index + pattern.count <= html.count else { return false }
            for offset in 0..<pattern.count
            where Character(html[index + offset].lowercased()) != pattern[offset] {
                return false
            }
            return true
        }

        private mutating func readText() -> String {
            var out = ""
            while !isAtEnd, html[index] != "<" {
                out.append(html[index])
                index += 1
            }
            // Markdown-generated HTML puts newlines between tags for
            // readability; they are not content.
            let collapsed = out.replacingOccurrences(
                of: "\\s+", with: " ", options: .regularExpression
            )
            return HTMLNode.decodeEntities(collapsed == " " ? "" : collapsed)
        }
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = text
        for (entity, replacement) in [
            ("&nbsp;", "\u{00A0}"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&amp;", "&")
        ] {
            out = out.replacingOccurrences(of: entity, with: replacement)
        }
        return out
    }
}
