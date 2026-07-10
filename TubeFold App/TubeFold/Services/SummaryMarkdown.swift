import Foundation

/// A small Markdown → HTML converter scoped to the syntax our summaries actually
/// use: a leading YAML front matter block (dropped), ATX headings, paragraphs,
/// ordered/unordered lists, blockquotes, fenced code, horizontal rules, and inline
/// bold/italic/strikethrough/code/links. Unknown syntax degrades to plain text.
///
/// This mirrors TubeFoldKit's Telegraph markdown parsing, with two
/// deliberate differences: the leading `# Title` is kept (the PDF wants it) and the
/// `_Generated with TubeFold_` footer is left in place.
///
/// Document assembly lives here; the block/inline parsing primitives live in
/// `SummaryMarkdown+Parsing.swift`.
enum SummaryMarkdown {
    /// Project credit, mirroring `SummaryText.projectName`/`projectURL`.
    private static let projectName = "TubeFold"
    private static let projectURL = "https://tubefold.github.io/"

    static func htmlDocument(markdown: String, title: String) -> String {
        // The pipeline records these in the summary's YAML front matter; the
        // Telegraph article surfaces them the same way (title/channel byline + a
        // "Summarized by <model>" credit). The PDF mirrors that.
        let videoURL = frontMatterValue(markdown, "url")
        let channel = frontMatterValue(markdown, "channel")
        let model = frontMatterValue(markdown, "model")
        let frontMatterTitle = frontMatterValue(markdown, "title")
        let displayTitle = frontMatterTitle.isEmpty ? title : frontMatterTitle

        // Drop the front matter, the body's own leading `# Title` (we render our own
        // linked header) and the `.md` credit footer (we render a richer one).
        let body = bodyHTML(markdown: stripFooter(stripLeadingTitle(stripFrontMatter(markdown))))

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>\(escape(displayTitle))</title>
        <style>
        \(stylesheet)
        </style>
        </head>
        <body>
        \(header(title: displayTitle, videoURL: videoURL, channel: channel))
        \(body)
        \(footer(model: model))
        </body>
        </html>
        """
    }

    /// Title (linked to the YouTube video when we have the URL) plus the channel name.
    private static func header(title: String, videoURL: String, channel: String) -> String {
        let heading = if videoURL.isEmpty {
            "<h1>\(escape(title))</h1>"
        } else {
            "<h1><a href=\"\(escapeAttribute(videoURL))\">\(escape(title))</a></h1>"
        }
        let byline = channel.isEmpty ? "" : "<p class=\"byline\">\(escape(channel))</p>"
        return "<header>\(heading)\(byline)</header>"
    }

    /// "Generated with TubeFold" plus a lighter "Summarized by <model>" line.
    private static func footer(model: String) -> String {
        var credit = "Generated with <a href=\"\(escapeAttribute(projectURL))\">\(escape(projectName))</a>"
        if !model.isEmpty {
            credit += "<br>Summarized by \(escape(model))"
        }
        return "<hr><p class=\"footer\"><em>\(credit)</em></p>"
    }

    // MARK: - Front matter / title / footer stripping

    /// Drop a leading `---`-delimited YAML front-matter block, if present.
    static func stripFrontMatter(_ markdown: String) -> String {
        var text = markdown
        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }
        guard text.hasPrefix("---\n") else { return text }
        // Find the closing delimiter line.
        let afterOpen = text.index(text.startIndex, offsetBy: 4)
        guard let closeRange = text.range(of: "\n---\n", range: afterOpen ..< text.endIndex) else {
            return text
        }
        let remainder = text[closeRange.upperBound...]
        return String(remainder).drop(while: { $0 == "\n" }).description
    }

    private static let leadingTitleRegex = regex("^#[ \\t]+\\S[^\\n]*\\n?")
    private static let footerRegex =
        regex("\\n*-{3,}[ \\t]*\\n+_Generated with \\[[^\\]]+\\]\\([^)]+\\)_[ \\t]*\\n*\\z")

    /// Drop a leading top-level `# Title` heading (we render our own linked title).
    /// Mirrors `telegraph.strip_leading_title`.
    private static func stripLeadingTitle(_ markdown: String) -> String {
        let head = String(markdown.drop(while: { $0 == "\n" }))
        let nsHead = head as NSString
        guard let titleMatch = leadingTitleRegex.firstMatch(
            in: head,
            options: [.anchored],
            range: NSRange(location: 0, length: nsHead.length),
        ) else {
            return markdown
        }
        let rest = nsHead.substring(from: titleMatch.range.length)
        return String(rest.drop(while: { $0 == "\n" }))
    }

    /// Drop a trailing `_Generated with [TubeFold](…)_` credit footer (we render a
    /// richer one). Mirrors `SummaryText.stripTubeFoldFooter`.
    private static func stripFooter(_ markdown: String) -> String {
        let nsText = markdown as NSString
        let range = NSRange(location: 0, length: nsText.length)
        return footerRegex.stringByReplacingMatches(in: markdown, options: [], range: range, withTemplate: "")
    }

    /// Read a single scalar from the leading YAML front matter. Values are written
    /// by the pipeline as JSON scalars (strings quoted), so a quoted value is
    /// JSON-decoded. Mirrors `telegraph.front_matter_value`. Returns "" if absent.
    static func frontMatterValue(_ markdown: String, _ key: String) -> String {
        var text = markdown
        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }
        guard text.hasPrefix("---\n") else { return "" }
        let afterOpen = text.index(text.startIndex, offsetBy: 4)
        guard let closeRange = text.range(of: "\n---\n", range: afterOpen ..< text.endIndex) else {
            return ""
        }
        let block = String(text[afterOpen ..< closeRange.lowerBound])
        for rawLine in block.components(separatedBy: "\n") {
            guard rawLine.hasPrefix("\(key):") else { continue }
            let raw = String(rawLine.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("\"") {
                if let data = raw.data(using: .utf8),
                   let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String
                {
                    return value
                }
            }
            return raw
        }
        return ""
    }

    // MARK: - Stylesheet

    private static let stylesheet = """
    :root { color-scheme: light; }
    body {
      font-family: -apple-system, "Helvetica Neue", Arial, sans-serif;
      font-size: 12pt;
      line-height: 1.55;
      color: #1a1a1a;
      /* createPDF captures the body box, so margins live here (not in print info). */
      margin: 0;
      padding: 48pt 56pt;
      box-sizing: border-box;
    }
    header { margin: 0 0 1.6em; }
    header h1 { margin: 0; }
    header h1 a { color: #1a5fb4; }
    .byline { color: #666; font-size: 11pt; margin: 0.2em 0 0; }
    .footer { color: #888; font-size: 10pt; margin: 0; }
    h1 { font-size: 22pt; line-height: 1.2; margin: 0 0 0.5em; }
    h2 { font-size: 16pt; margin: 1.5em 0 0.4em; }
    h3 { font-size: 13pt; margin: 1.3em 0 0.3em; }
    h4, h5, h6 { font-size: 12pt; margin: 1.1em 0 0.3em; }
    h1, h2, h3, h4, h5, h6 { break-after: avoid-page; }
    p { margin: 0 0 0.8em; orphans: 2; widows: 2; }
    ul, ol { margin: 0 0 0.8em; padding-left: 1.4em; }
    li { margin: 0.2em 0; }
    blockquote {
      margin: 0 0 0.8em;
      padding: 0.2em 0 0.2em 1em;
      border-left: 3px solid #d0d0d0;
      color: #555;
    }
    code {
      font-family: "SF Mono", Menlo, monospace;
      font-size: 0.9em;
      background: #f2f2f2;
      padding: 0.1em 0.3em;
      border-radius: 3px;
    }
    pre {
      background: #f6f6f6;
      padding: 0.8em 1em;
      border-radius: 6px;
      overflow-wrap: break-word;
      white-space: pre-wrap;
    }
    pre code { background: none; padding: 0; }
    a { color: #0a66c2; text-decoration: none; }
    hr { border: none; border-top: 1px solid #ddd; margin: 1.5em 0; }
    """
}
