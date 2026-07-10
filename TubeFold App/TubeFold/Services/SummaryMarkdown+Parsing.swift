import Foundation

/// Block and inline Markdown parsing behind `SummaryMarkdown.htmlDocument`.
extension SummaryMarkdown {
    // MARK: - Block parsing

    static func bodyHTML(markdown: String) -> String {
        let source = stripFrontMatter(markdown)
        let lines = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var parser = BlockParser(lines: lines)
        return parser.parse()
    }

    /// Line-by-line scanner: walks `lines` once, emitting one HTML fragment per
    /// top-level Markdown block and accumulating everything else into paragraphs.
    private struct BlockParser {
        let lines: [String]
        var index = 0
        var html: [String] = []
        var paragraph: [String] = []

        mutating func parse() -> String {
            while index < lines.count {
                let line = lines[index]
                let stripped = line.trimmingCharacters(in: .whitespaces)

                if stripped.isEmpty {
                    flushParagraph()
                    index += 1
                } else if let fence = firstGroup(fenceRegex, line, 1) {
                    appendFencedCode(closingFence: fence)
                } else if let headingMatch = match(headingRegex, line) {
                    appendHeading(headingMatch, line: line)
                } else if match(hrRegex, line) != nil {
                    flushParagraph()
                    html.append("<hr>")
                    index += 1
                } else if match(ulRegex, line) != nil {
                    appendList(itemRegex: ulRegex, tag: "ul")
                } else if match(olRegex, line) != nil {
                    appendList(itemRegex: olRegex, tag: "ol")
                } else if match(blockquoteRegex, line) != nil {
                    appendBlockquote()
                } else {
                    paragraph.append(line)
                    index += 1
                }
            }
            flushParagraph()
            return html.joined(separator: "\n")
        }

        private mutating func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let text = paragraph
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                html.append("<p>\(inlineHTML(text))</p>")
            }
            paragraph.removeAll()
        }

        private mutating func appendFencedCode(closingFence: String) {
            flushParagraph()
            index += 1
            var code: [String] = []
            while index < lines.count,
                  !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(closingFence)
            {
                code.append(lines[index])
                index += 1
            }
            index += 1 // consume closing fence
            html.append("<pre><code>\(escape(code.joined(separator: "\n")))</code></pre>")
        }

        private mutating func appendHeading(_ headingMatch: NSTextCheckingResult, line: String) {
            flushParagraph()
            let hashes = group(headingMatch, line, 1)
            let level = min(max(hashes.count, 1), 6)
            let text = group(headingMatch, line, 2).trimmingCharacters(in: .whitespaces)
            html.append("<h\(level)>\(inlineHTML(text))</h\(level)>")
            index += 1
        }

        private mutating func appendList(itemRegex: NSRegularExpression, tag: String) {
            flushParagraph()
            var items: [String] = []
            while index < lines.count, let itemMatch = match(itemRegex, lines[index]) {
                let text = group(itemMatch, lines[index], 1).trimmingCharacters(in: .whitespaces)
                items.append("<li>\(inlineHTML(text))</li>")
                index += 1
            }
            html.append("<\(tag)>\(items.joined())</\(tag)>")
        }

        private mutating func appendBlockquote() {
            flushParagraph()
            var quote: [String] = []
            while index < lines.count, let quoteMatch = match(blockquoteRegex, lines[index]) {
                quote.append(group(quoteMatch, lines[index], 1).trimmingCharacters(in: .whitespaces))
                index += 1
            }
            let text = quote.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            html.append("<blockquote>\(inlineHTML(text))</blockquote>")
        }
    }

    // MARK: - Inline parsing (earliest-match-wins, recursive)

    private enum Inline { case code, link, bold, italic, strike }

    private static let inlinePatterns: [(Inline, NSRegularExpression)] = [
        (.code, regex("`([^`]+)`")),
        (.link, regex("\\[([^\\]]+)\\]\\(([^)\\s]+)\\)")),
        (.bold, regex("\\*\\*([^*]+)\\*\\*|__([^_]+)__")),
        (.italic, regex("\\*([^*]+)\\*|_([^_]+)_")),
        (.strike, regex("~~([^~]+)~~")),
    ]

    static func inlineHTML(_ text: String) -> String {
        if text.isEmpty {
            return ""
        }
        let nsText = text as NSString

        guard let (kind, result) = earliestInlineMatch(in: text) else { return escape(text) }

        var out = ""
        if result.range.location > 0 {
            out += escape(nsText.substring(with: NSRange(location: 0, length: result.range.location)))
        }
        out += renderInline(kind, result, nsText)

        let restStart = result.range.location + result.range.length
        if restStart < nsText.length {
            out += inlineHTML(nsText.substring(from: restStart))
        }
        return out
    }

    /// The inline pattern whose match starts earliest in `text`, or nil if none match.
    private static func earliestInlineMatch(in text: String) -> (Inline, NSTextCheckingResult)? {
        let full = NSRange(location: 0, length: (text as NSString).length)
        var best: (kind: Inline, match: NSTextCheckingResult)?
        for (kind, regex) in inlinePatterns {
            guard let result = regex.firstMatch(in: text, options: [], range: full) else { continue }
            if let current = best, current.match.range.location <= result.range.location {
                continue
            }
            best = (kind, result)
        }
        guard let best else { return nil }
        return (best.kind, best.match)
    }

    private static func renderInline(_ kind: Inline, _ result: NSTextCheckingResult, _ nsText: NSString) -> String {
        switch kind {
        case .code:
            return "<code>\(escape(firstNonEmptyGroup(result, nsText)))</code>"
        case .link:
            let label = nsText.substring(with: result.range(at: 1))
            let href = nsText.substring(with: result.range(at: 2))
            return "<a href=\"\(escapeAttribute(href))\">\(inlineHTML(label))</a>"
        case .bold:
            return "<strong>\(inlineHTML(firstNonEmptyGroup(result, nsText)))</strong>"
        case .italic:
            return "<em>\(inlineHTML(firstNonEmptyGroup(result, nsText)))</em>"
        case .strike:
            return "<s>\(inlineHTML(firstNonEmptyGroup(result, nsText)))</s>"
        }
    }

    // MARK: - Regex helpers

    private static let headingRegex = regex("^(#{1,6})\\s+(.*)$")
    private static let hrRegex = regex("^\\s*([-*_])\\1{2,}\\s*$")
    private static let ulRegex = regex("^\\s*[-*+]\\s+(.*)$")
    private static let olRegex = regex("^\\s*\\d+[.)]\\s+(.*)$")
    private static let blockquoteRegex = regex("^\\s*>\\s?(.*)$")
    private static let fenceRegex = regex("^\\s*(```|~~~)")

    static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are static and known-valid; a bad one is a programmer error.
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            preconditionFailure("Invalid built-in Markdown pattern: \(pattern)")
        }
        return regex
    }

    private static func match(_ regex: NSRegularExpression, _ line: String) -> NSTextCheckingResult? {
        let nsLine = line as NSString
        return regex.firstMatch(in: line, options: [], range: NSRange(location: 0, length: nsLine.length))
    }

    private static func group(_ match: NSTextCheckingResult, _ line: String, _ index: Int) -> String {
        let range = match.range(at: index)
        guard range.location != NSNotFound else { return "" }
        return (line as NSString).substring(with: range)
    }

    /// First capture group of `regex` in `line`, or nil if no match.
    private static func firstGroup(_ regex: NSRegularExpression, _ line: String, _ index: Int) -> String? {
        guard let lineMatch = match(regex, line) else { return nil }
        let range = lineMatch.range(at: index)
        guard range.location != NSNotFound else { return nil }
        return (line as NSString).substring(with: range)
    }

    /// Picks the first non-nil capture group — the
    /// first non-empty alternation group (bold/italic each have two).
    private static func firstNonEmptyGroup(_ match: NSTextCheckingResult, _ nsText: NSString) -> String {
        for groupIndex in 1 ..< match.numberOfRanges {
            let range = match.range(at: groupIndex)
            if range.location != NSNotFound {
                return nsText.substring(with: range)
            }
        }
        return ""
    }

    // MARK: - HTML escaping

    static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func escapeAttribute(_ text: String) -> String {
        escape(text).replacingOccurrences(of: "\"", with: "&quot;")
    }
}
