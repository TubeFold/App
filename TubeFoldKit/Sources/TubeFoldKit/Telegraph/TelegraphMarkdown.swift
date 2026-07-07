import Foundation

/// Markdown → Telegraph node conversion.
///
/// Handles the constructs our summaries actually use: ATX headings (mapped to
/// `h3`/`h4` since Telegraph forbids `h1`/`h2`), paragraphs, ordered and
/// unordered lists, blockquotes, fenced code blocks, horizontal rules, and
/// inline bold/italic/strikethrough/code/links. Unknown syntax degrades to
/// plain text.
public enum TelegraphMarkdown {
    // MARK: - Front matter

    nonisolated(unsafe) private static let frontMatterRegex =
        /^---\n.*?\n---\n/.dotMatchesNewlines()

    private static func withoutBOM(_ markdown: String) -> Substring {
        var text = Substring(markdown)
        while text.hasPrefix("\u{FEFF}") {
            text = text.dropFirst()
        }
        return text
    }

    /// Remove a leading `---`-delimited YAML front-matter block, if present.
    public static func stripFrontMatter(_ markdown: String) -> String {
        var text = withoutBOM(markdown)
        if let match = text.prefixMatch(of: frontMatterRegex) {
            text = text[match.range.upperBound...]
        }
        while text.hasPrefix("\n") {
            text = text.dropFirst()
        }
        return String(text)
    }

    /// Read a single scalar value from a summary's leading YAML front matter.
    ///
    /// Values are written by `SummaryText.yamlFrontMatter` as JSON scalars
    /// (strings are quoted), so a quoted value is JSON-decoded; anything else
    /// is returned verbatim. Returns `""` when there is no front matter or no
    /// such key.
    public static func frontMatterValue(_ markdown: String, key: String) -> String {
        let text = withoutBOM(markdown)
        guard let match = text.prefixMatch(of: frontMatterRegex) else {
            return ""
        }
        let block = text[match.range]
        for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.hasPrefix("\(key):") else { continue }
            let raw = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("\"") {
                if let data = raw.data(using: .utf8),
                   let decoded = try? JSONDecoder().decode(String.self, from: data) {
                    return decoded
                }
                return raw
            }
            return raw
        }
        return ""
    }

    nonisolated(unsafe) private static let leadingH1Regex = /#[ \t]+\S[^\n]*\n?/

    /// Drop a leading top-level `# Title` heading from a summary body.
    ///
    /// Telegraph sets the page title itself, so the body's first heading (the
    /// pipeline always opens with `# {{TITLE}}`) would just render a
    /// duplicate. Only a single-`#` heading at the very top is removed;
    /// section headings (`##` and deeper) are left untouched.
    public static func stripLeadingTitle(_ markdown: String) -> String {
        var head = Substring(markdown)
        while head.hasPrefix("\n") {
            head = head.dropFirst()
        }
        if let match = head.prefixMatch(of: leadingH1Regex) {
            var rest = head[match.range.upperBound...]
            while rest.hasPrefix("\n") {
                rest = rest.dropFirst()
            }
            return String(rest)
        }
        return markdown
    }

    // MARK: - Block-level parsing

    nonisolated(unsafe) private static let headingRegex = /^(#{1,6})\s+(.*)$/
    nonisolated(unsafe) private static let hrRegex = /^\s*([-*_])\1{2,}\s*$/
    nonisolated(unsafe) private static let ulRegex = /^\s*[-*+]\s+(.*)$/
    nonisolated(unsafe) private static let olRegex = /^\s*\d+[.)]\s+(.*)$/
    nonisolated(unsafe) private static let blockquoteRegex = /^\s*>\s?(.*)$/
    nonisolated(unsafe) private static let fenceRegex = /^\s*(```|~~~)/

    /// Convert summary Markdown (body only) into a Telegraph content node array.
    public static func markdownToNodes(_ markdown: String) -> [TelegraphNode] {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var nodes: [TelegraphNode] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let text = paragraph
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                nodes.append(.element(tag: "p", children: inlineNodes(text)))
            }
            paragraph.removeAll()
        }

        while index < lines.count {
            let line = lines[index]
            let stripped = line.trimmingCharacters(in: .whitespaces)

            if stripped.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let fenceMatch = line.prefixMatch(of: fenceRegex) {
                flushParagraph()
                let fence = String(fenceMatch.output.1)
                index += 1
                var codeLines: [String] = []
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    codeLines.append(lines[index])
                    index += 1
                }
                index += 1 // consume closing fence
                nodes.append(.element(tag: "pre", children: [.text(codeLines.joined(separator: "\n"))]))
                continue
            }

            if let heading = line.wholeMatch(of: headingRegex) {
                flushParagraph()
                let level = heading.output.1.count
                let tag = level <= 2 ? "h3" : "h4"
                let text = String(heading.output.2).trimmingCharacters(in: .whitespaces)
                nodes.append(.element(tag: tag, children: inlineNodes(text)))
                index += 1
                continue
            }

            if line.wholeMatch(of: hrRegex) != nil {
                flushParagraph()
                nodes.append(.element(tag: "hr"))
                index += 1
                continue
            }

            if line.wholeMatch(of: ulRegex) != nil {
                flushParagraph()
                var items: [TelegraphNode] = []
                while index < lines.count, let item = lines[index].wholeMatch(of: ulRegex) {
                    items.append(listItem(String(item.output.1)))
                    index += 1
                }
                nodes.append(.element(tag: "ul", children: items))
                continue
            }

            if line.wholeMatch(of: olRegex) != nil {
                flushParagraph()
                var items: [TelegraphNode] = []
                while index < lines.count, let item = lines[index].wholeMatch(of: olRegex) {
                    items.append(listItem(String(item.output.1)))
                    index += 1
                }
                nodes.append(.element(tag: "ol", children: items))
                continue
            }

            if line.wholeMatch(of: blockquoteRegex) != nil {
                flushParagraph()
                var quoteLines: [String] = []
                while index < lines.count, let quote = lines[index].wholeMatch(of: blockquoteRegex) {
                    quoteLines.append(String(quote.output.1))
                    index += 1
                }
                let text = quoteLines
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
                nodes.append(.element(tag: "blockquote", children: inlineNodes(text)))
                continue
            }

            paragraph.append(line)
            index += 1
        }

        flushParagraph()
        return nodes
    }

    private static func listItem(_ text: String) -> TelegraphNode {
        .element(tag: "li", children: inlineNodes(text.trimmingCharacters(in: .whitespaces)))
    }

    // MARK: - Inline parsing

    private enum InlineKind {
        case code, link, bold, italic, strike
    }

    private struct InlineMatch {
        let kind: InlineKind
        let range: Range<String.Index>
        let inner: String
        let href: String?
    }

    // Inline patterns, scanned earliest-match-wins. Code spans win over
    // everything else so their contents stay literal.
    nonisolated(unsafe) private static let codeRegex = /`([^`]+)`/
    nonisolated(unsafe) private static let linkRegex = /\[([^\]]+)\]\(([^)\s]+)\)/
    nonisolated(unsafe) private static let boldRegex = /\*\*([^*]+)\*\*|__([^_]+)__/
    nonisolated(unsafe) private static let italicRegex = /\*([^*]+)\*|_([^_]+)_/
    nonisolated(unsafe) private static let strikeRegex = /~~([^~]+)~~/

    private static func earliestMatch(in text: String) -> InlineMatch? {
        var best: InlineMatch?

        func consider(_ kind: InlineKind, _ range: Range<String.Index>?, inner: String, href: String? = nil) {
            guard let range else { return }
            if best == nil || range.lowerBound < best!.range.lowerBound {
                best = InlineMatch(kind: kind, range: range, inner: inner, href: href)
            }
        }

        if let match = text.firstMatch(of: codeRegex) {
            consider(.code, match.range, inner: String(match.output.1))
        }
        if let match = text.firstMatch(of: linkRegex) {
            consider(.link, match.range, inner: String(match.output.1), href: String(match.output.2))
        }
        if let match = text.firstMatch(of: boldRegex) {
            consider(.bold, match.range, inner: String(match.output.1 ?? match.output.2 ?? ""))
        }
        if let match = text.firstMatch(of: italicRegex) {
            consider(.italic, match.range, inner: String(match.output.1 ?? match.output.2 ?? ""))
        }
        if let match = text.firstMatch(of: strikeRegex) {
            consider(.strike, match.range, inner: String(match.output.1))
        }
        return best
    }

    /// Convert a single line of inline Markdown into a list of Telegraph nodes.
    static func inlineNodes(_ text: String) -> [TelegraphNode] {
        guard !text.isEmpty else { return [] }
        guard let match = earliestMatch(in: text) else {
            return [.text(text)]
        }

        var nodes: [TelegraphNode] = []
        if match.range.lowerBound > text.startIndex {
            nodes.append(.text(String(text[..<match.range.lowerBound])))
        }

        switch match.kind {
        case .code:
            nodes.append(.element(tag: "code", children: [.text(match.inner)]))
        case .link:
            nodes.append(.element(
                tag: "a",
                attrs: ["href": match.href ?? ""],
                children: inlineNodes(match.inner)
            ))
        case .bold:
            nodes.append(.element(tag: "strong", children: inlineNodes(match.inner)))
        case .italic:
            nodes.append(.element(tag: "em", children: inlineNodes(match.inner)))
        case .strike:
            nodes.append(.element(tag: "s", children: inlineNodes(match.inner)))
        }

        nodes.append(contentsOf: inlineNodes(String(text[match.range.upperBound...])))
        return nodes
    }
}
