import Foundation

/// A parsed piece of a formula.
///
/// Lesson bodies carry LaTeX between `\( … \)`, the same source the web renders
/// with KaTeX. Across every published maths lesson only nine commands appear,
/// and `\dfrac` is the only one that needs real layout — so this models the
/// notation the content uses rather than TeX at large.
///
/// Anything unrecognised survives as literal text. A visibly wrong `\foo` in a
/// lesson is a bug someone reports; a silently dropped one is a bug nobody sees.
public indirect enum MathNode: Sendable, Hashable {
    /// Literal characters, with commands like `\times` already read as `×`.
    case text(String)
    case fraction(numerator: [MathNode], denominator: [MathNode])
    case power(base: [MathNode], exponent: [MathNode])
    case root([MathNode])
    /// `\left( … \right)` — brackets sized to fit what they hold.
    case bracketed(open: String, close: String, body: [MathNode])
    case space
}

/// One stretch of a lesson sentence: prose, or a formula waiting to be parsed.
public enum MathSegment: Sendable, Equatable {
    case prose(String)
    /// The LaTeX between the delimiters, which are stripped.
    case formula(String)
}

public enum MathExpressionParser {

    // MARK: - Finding formulas in prose

    /// Splits a sentence on the `\( … \)` delimiters that lesson bodies use.
    ///
    /// An unclosed `\(` stays prose. Half a formula is a content bug, and
    /// swallowing the rest of the sentence would hide it.
    public static func segments(in text: String) -> [MathSegment] {
        guard text.contains("\\(") else { return [.prose(text)] }

        var segments: [MathSegment] = []
        var remainder = Substring(text)

        while let open = remainder.range(of: "\\(") {
            guard let close = remainder[open.upperBound...].range(of: "\\)") else { break }

            let before = remainder[..<open.lowerBound]
            if !before.isEmpty { segments.append(.prose(String(before))) }

            segments.append(.formula(String(remainder[open.upperBound..<close.lowerBound])))
            remainder = remainder[close.upperBound...]
        }

        if !remainder.isEmpty { segments.append(.prose(String(remainder))) }
        return segments
    }

    // MARK: - Parsing a formula

    public static func parse(_ latex: String) -> [MathNode] {
        var scanner = Scanner(characters: Array(latex))
        return scanner.parseNodes(stoppingAtBrace: false)
    }

    /// Commands that are just a character once read.
    fileprivate static let symbols: [String: String] = [
        "times": "×", "div": "÷", "cdot": "⋅",
        "neq": "≠", "ne": "≠",
        "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥",
        "pm": "±", "mp": "∓",
        "ldots": "…", "dots": "…", "cdots": "…",
        "square": "□", "circ": "°", "infty": "∞"
    ]

    /// Commands that only add room around a term.
    fileprivate static let spacingCommands: Set<String> = ["quad", "qquad", ",", ";", "!", " "]

    fileprivate static let fractionCommands: Set<String> = ["frac", "dfrac", "tfrac"]

    private struct Scanner {
        let characters: [Character]
        var index = 0
        /// Set when a `\right` is reached, so the matching `\left` can read it.
        var closingDelimiter = ""

        var isAtEnd: Bool { index >= characters.count }

        mutating func parseNodes(stoppingAtBrace: Bool) -> [MathNode] {
            var result: [MathNode] = []
            var literal = ""

            func flush() {
                if !literal.isEmpty {
                    result.append(.text(literal))
                    literal = ""
                }
            }

            while !isAtEnd {
                let character = characters[index]

                if character == "}" {
                    index += 1
                    if stoppingAtBrace { break }
                    continue    // a stray brace is not worth losing the rest over
                }

                if character == "{" {
                    index += 1
                    flush()
                    result += parseNodes(stoppingAtBrace: true)
                    continue
                }

                if character == "^" {
                    index += 1
                    let base = raiseBase(&result, &literal)
                    flush()     // whatever came before the base still leads
                    result.append(.power(base: base, exponent: parseArgument()))
                    continue
                }

                guard character == "\\" else {
                    literal.append(character)
                    index += 1
                    continue
                }

                let command = readCommand()

                if command == "right" {
                    closingDelimiter = readDelimiter()
                    flush()
                    return result
                }

                if command == "left" {
                    let open = readDelimiter()
                    flush()
                    let body = parseNodes(stoppingAtBrace: false)
                    result.append(.bracketed(
                        open: open, close: closingDelimiter, body: trimmingOuterSpaces(body)
                    ))
                    continue
                }

                if MathExpressionParser.fractionCommands.contains(command) {
                    flush()
                    let numerator = parseArgument()
                    result.append(.fraction(numerator: numerator, denominator: parseArgument()))
                    continue
                }

                if command == "sqrt" {
                    flush()
                    result.append(.root(parseArgument()))
                    continue
                }

                if MathExpressionParser.spacingCommands.contains(command) {
                    literal.append(" ")
                    continue
                }

                if let symbol = MathExpressionParser.symbols[command] {
                    literal.append(symbol)
                    continue
                }

                // An escaped character — `\{`, `\%` — is itself.
                if command.count == 1, !(command.first?.isLetter ?? false) {
                    literal.append(command)
                    continue
                }

                literal.append("\\" + command)
            }

            flush()
            return result
        }

        /// The argument to `\dfrac`, `\sqrt` or `^`: a braced group, a single
        /// command, or one character.
        private mutating func parseArgument() -> [MathNode] {
            while !isAtEnd, characters[index] == " " { index += 1 }
            guard !isAtEnd else { return [] }

            if characters[index] == "{" {
                index += 1
                return parseNodes(stoppingAtBrace: true)
            }

            if characters[index] == "\\" {
                let command = readCommand()
                return [.text(MathExpressionParser.symbols[command] ?? "\\" + command)]
            }

            let character = characters[index]
            index += 1
            return [.text(String(character))]
        }

        /// Room just inside a bracket is LaTeX layout, not content: authors write
        /// `\left( x \right)` for legibility, but it reads as `(x)`.
        private func trimmingOuterSpaces(_ nodes: [MathNode]) -> [MathNode] {
            var trimmed = nodes

            if case let .text(value)? = trimmed.first {
                let stripped = String(value.drop(while: { $0 == " " }))
                if stripped.isEmpty { trimmed.removeFirst() } else { trimmed[0] = .text(stripped) }
            }

            if case let .text(value)? = trimmed.last {
                var stripped = value
                while stripped.hasSuffix(" ") { stripped.removeLast() }
                if stripped.isEmpty {
                    trimmed.removeLast()
                } else {
                    trimmed[trimmed.count - 1] = .text(stripped)
                }
            }

            return trimmed
        }

        /// `3x^2` raises only the `x`, not everything written before it.
        private func raiseBase(_ result: inout [MathNode], _ literal: inout String) -> [MathNode] {
            if let last = literal.last {
                literal.removeLast()
                return [.text(String(last))]
            }
            guard let last = result.popLast() else { return [] }
            return [last]
        }

        private mutating func readCommand() -> String {
            index += 1                              // consume the backslash
            guard !isAtEnd else { return "" }

            guard characters[index].isLetter else {
                let character = characters[index]
                index += 1
                return String(character)
            }

            var name = ""
            while !isAtEnd, characters[index].isLetter {
                name.append(characters[index])
                index += 1
            }
            return name
        }

        /// The bracket after `\left` or `\right`. A `.` means "nothing here".
        private mutating func readDelimiter() -> String {
            while !isAtEnd, characters[index] == " " { index += 1 }
            guard !isAtEnd else { return "" }

            if characters[index] == "\\" {
                return MathExpressionParser.symbols[readCommand()] ?? ""
            }

            let character = characters[index]
            index += 1
            return character == "." ? "" : String(character)
        }
    }
}

// MARK: - Written form

public extension MathNode {
    /// How the formula reads on one line — the fallback wherever stacked
    /// layout is unavailable, and what `InlineText.plain` reports.
    var plain: String {
        switch self {
        case let .text(value):
            value
        case let .fraction(numerator, denominator):
            "\(numerator.grouped)/\(denominator.grouped)"
        case let .power(base, exponent):
            "\(base.grouped)^\(exponent.grouped)"
        case let .root(body):
            "√\(body.grouped)"
        case let .bracketed(open, close, body):
            open + body.plain + close
        case .space:
            " "
        }
    }

    /// True when this needs stacked layout rather than a line of text.
    var needsLayout: Bool {
        switch self {
        case .text, .space:
            false
        case .fraction, .root:
            true
        case let .power(base, exponent):
            base.needsLayout || exponent.needsLayout
        case let .bracketed(_, _, body):
            body.needsLayout
        }
    }
}

public extension [MathNode] {
    var plain: String { map(\.plain).joined() }

    var needsLayout: Bool { contains(where: \.needsLayout) }
}

extension [MathNode] {
    /// Brackets a part only when running it together would change the reading:
    /// `(x+1)/3`, but `x/3`.
    var grouped: String {
        let written = plain
        let runsTogether = written.count > 1 && written.contains { "+-−×÷ ".contains($0) }
        return runsTogether ? "(\(written))" : written
    }
}

// MARK: - Spoken form

public extension MathNode {
    /// What VoiceOver should say. `\dfrac{x}{2}` has to read 「2ぶんのx」;
    /// read left to right it becomes "x 2", which is a different sum.
    var spoken: String {
        switch self {
        case let .text(value):
            MathSpeech.read(value)
        case let .fraction(numerator, denominator):
            "\(denominator.spoken)ぶんの\(numerator.spoken)"
        case let .power(base, exponent):
            "\(base.spoken)の\(exponent.spoken)乗"
        case let .root(body):
            "ルート\(body.spoken)"
        case let .bracketed(_, _, body):
            "かっこ \(body.spoken) かっことじ"
        case .space:
            " "
        }
    }
}

public extension [MathNode] {
    var spoken: String {
        map(\.spoken)
            .joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}

/// Turns operators into words. Numbers and letters already read correctly.
enum MathSpeech {
    private static let words: [Character: String] = [
        "=": "イコール", "+": "たす", "×": "かける", "÷": "わる",
        "≠": "イコールではない", "≤": "以下", "≥": "以上",
        "±": "プラスマイナス", "⋅": "かける", "□": "しかく",
        "(": "かっこ", ")": "かっことじ", ":": "たい"
    ]

    /// After one of these a minus sign is a sign, not a subtraction.
    private static let operators: Set<Character> = ["=", "+", "×", "÷", "≠", "≤", "≥", "(", ":", "-", "−"]

    static func read(_ text: String) -> String {
        var spoken: [String] = []
        var token = ""
        var previous: Character?

        func flush() {
            if !token.isEmpty {
                spoken.append(token)
                token = ""
            }
        }

        for character in text {
            // Spaces separate terms but leave `previous` alone, so the minus in
            // `x - 3` still knows an `x` came before it.
            if character == " " {
                flush()
                continue
            }

            if character == "-" || character == "−" {
                flush()
                let isSign = previous.map(operators.contains) ?? true
                spoken.append(isSign ? "マイナス" : "ひく")
            } else if let word = words[character] {
                flush()
                spoken.append(word)
            } else {
                token.append(character)
            }
            previous = character
        }

        flush()
        return spoken.joined(separator: " ")
    }
}
