import AppKit
import Foundation
import PDFKit
import WebKit

/// Turns a summary's Markdown into PDF data, entirely with Apple frameworks (no
/// third-party Markdown or PDF dependency).
///
/// The flow is: our own small Markdown → HTML converter (`SummaryMarkdown`),
/// wrapped in a styled HTML document, loaded into an offscreen `WKWebView`, then
/// snapshotted to PDF via `WKWebView.createPDF`. Keeping WebKit as the renderer
/// is important: it is the engine that understands the CSS in `SummaryMarkdown`.
///
/// `WKWebView.createPDF` emits one continuous page sized to the content. The
/// renderer keeps that reliable path, then paginates the resulting PDF into A4
/// pages as a separate PDF post-processing step.
@MainActor
final class SummaryPDFRenderer: NSObject, WKNavigationDelegate {
    enum RenderError: LocalizedError {
        case loadFailed(Error)
        case pdfFailed(Error?)

        var errorDescription: String? {
            switch self {
            case let .loadFailed(error):
                "Couldn't lay out the summary for PDF: \(error.localizedDescription)"
            case let .pdfFailed(error):
                if let error {
                    "Couldn't render the PDF: \(error.localizedDescription)"
                } else {
                    "Couldn't render the PDF."
                }
            }
        }
    }

    /// A4 in points (210 × 297 mm at 72 dpi).
    private static let paperSize = NSSize(width: 595.28, height: 841.89)

    // Held for the lifetime of a single render so the web view isn't deallocated
    // mid-snapshot.
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Data, Error>?

    /// Render `markdown` to paginated PDF data. `title` becomes the document title.
    func makePDFData(markdown: String, title: String) async throws -> Data {
        let html = SummaryMarkdown.htmlDocument(markdown: markdown, title: title)
        let frame = NSRect(origin: .zero, size: Self.paperSize)
        let webView = WKWebView(frame: frame, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = self
        self.webView = webView

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        // Add blank page-break spacers to the WebKit document before snapshotting.
        // The HTML/CSS rendering stays WebKit's; the spacers only make the later
        // PDF slicing land between top-level Markdown blocks.
        webView.evaluateJavaScript(Self.paginationScript(pageHeight: Self.paperSize.height)) { [weak self] value, error in
            guard let self else { return }
            guard error == nil else {
                finish(.failure(.pdfFailed(error)))
                return
            }

            // Grow the web view to the full content height so `createPDF`
            // captures the exact same WebKit-rendered document the old exporter
            // produced, now with explicit page gaps.
            if let height = (value as? NSNumber)?.doubleValue, height > 0 {
                webView.frame.size.height = CGFloat(height)
            }

            let configuration = WKPDFConfiguration()
            configuration.rect = webView.bounds
            webView.createPDF(configuration: configuration) { result in
                switch result {
                case let .success(data):
                    do {
                        let paginated = try Self.paginate(pdfData: data)
                        self.finish(.success(paginated))
                    } catch {
                        self.finish(.failure(.pdfFailed(error)))
                    }
                case let .failure(error):
                    self.finish(.failure(.pdfFailed(error)))
                }
            }
        }
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        finish(.failure(.loadFailed(error)))
    }

    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        finish(.failure(.loadFailed(error)))
    }

    private func finish(_ result: Result<Data, RenderError>) {
        guard let continuation else { return }
        self.continuation = nil
        webView = nil
        switch result {
        case let .success(data):
            continuation.resume(returning: data)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }

    private static func paginate(pdfData data: Data) throws -> Data {
        guard let provider = CGDataProvider(data: data as CFData),
              let sourceDocument = CGPDFDocument(provider),
              let sourcePage = sourceDocument.page(at: 1)
        else {
            throw RenderError.pdfFailed(nil)
        }

        let sourceBox = sourcePage.getBoxRect(.mediaBox)
        guard sourceBox.width > 0, sourceBox.height > 0 else {
            throw RenderError.pdfFailed(nil)
        }

        let outputData = NSMutableData()
        guard let consumer = CGDataConsumer(data: outputData) else {
            throw RenderError.pdfFailed(nil)
        }

        var mediaBox = CGRect(origin: .zero, size: paperSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw RenderError.pdfFailed(nil)
        }

        let scale = paperSize.width / sourceBox.width
        let scaledHeight = sourceBox.height * scale
        let pageCount = max(1, Int(ceil(scaledHeight / paperSize.height)))
        let annotations = PDFDocument(data: data)?.page(at: 0)?.annotations ?? []

        for pageIndex in 0 ..< pageCount {
            context.beginPDFPage(nil)
            context.saveGState()
            context.clip(to: mediaBox)

            let yOffset = paperSize.height - scaledHeight + CGFloat(pageIndex) * paperSize.height
            context.translateBy(x: 0, y: yOffset)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -sourceBox.minX, y: -sourceBox.minY)
            context.drawPDFPage(sourcePage)

            context.restoreGState()
            addLinkAnnotations(
                annotations,
                sourceBox: sourceBox,
                pageIndex: pageIndex,
                yOffset: yOffset,
                scale: scale,
                context: context,
                mediaBox: mediaBox,
            )
            context.endPDFPage()
        }

        context.closePDF()
        return outputData as Data
    }

    private static func addLinkAnnotations(
        _ annotations: [PDFAnnotation],
        sourceBox: CGRect,
        pageIndex _: Int,
        yOffset: CGFloat,
        scale: CGFloat,
        context: CGContext,
        mediaBox: CGRect,
    ) {
        for annotation in annotations {
            guard let url = annotation.url else { continue }
            let sourceBounds = annotation.bounds
            let targetBounds = CGRect(
                x: (sourceBounds.minX - sourceBox.minX) * scale,
                y: (sourceBounds.minY - sourceBox.minY) * scale + yOffset,
                width: sourceBounds.width * scale,
                height: sourceBounds.height * scale,
            )
            let clipped = targetBounds.intersection(mediaBox)
            guard !clipped.isNull, !clipped.isEmpty else { continue }
            context.setURL(url as CFURL, for: clipped)
        }
    }

    private static func paginationScript(pageHeight: CGFloat) -> String {
        let pageHeight = String(format: "%.3f", pageHeight)
        return """
        (() => {
          const pageHeight = \(pageHeight);
          const body = document.body;
          const style = window.getComputedStyle(body);
          const topPadding = parseFloat(style.paddingTop) || 0;
          const bottomPadding = parseFloat(style.paddingBottom) || topPadding;
          const usableHeight = Math.max(1, pageHeight - topPadding - bottomPadding);

          document.querySelectorAll('[data-tubefold-page-break]').forEach((node) => node.remove());

          const isHeading = (element) => /^H[1-6]$/.test(element.tagName);
          const nextContentElement = (element) => {
            let next = element.nextElementSibling;
            while (next && next.dataset.tubefoldPageBreak === 'true') {
              next = next.nextElementSibling;
            }
            return next;
          };
          const rectFor = (element) => element.getBoundingClientRect();
          const pageIndexFor = (top) => Math.floor(Math.max(0, top) / pageHeight);
          const pageContentTop = (pageIndex) => pageIndex * pageHeight + topPadding;
          const pageContentBottom = (pageIndex) => (pageIndex + 1) * pageHeight - bottomPadding;

          for (const element of Array.from(body.children)) {
            if (element.dataset.tubefoldPageBreak === 'true') continue;

            const rect = rectFor(element);
            const top = rect.top + window.scrollY;
            let bottom = rect.bottom + window.scrollY;

            if (isHeading(element)) {
              const next = nextContentElement(element);
              if (next) {
                bottom = Math.max(bottom, rectFor(next).bottom + window.scrollY);
              }
            }

            const height = bottom - top;
            if (height > usableHeight) continue;

            const pageIndex = pageIndexFor(top);
            const contentTop = pageContentTop(pageIndex);
            const contentBottom = pageContentBottom(pageIndex);
            if (top <= contentTop || bottom <= contentBottom) continue;

            const spacer = document.createElement('div');
            spacer.dataset.tubefoldPageBreak = 'true';
            spacer.setAttribute('aria-hidden', 'true');
            spacer.style.display = 'block';
            spacer.style.height = `${Math.max(0, pageContentTop(pageIndex + 1) - top)}px`;
            spacer.style.margin = '0';
            spacer.style.padding = '0';
            spacer.style.border = '0';
            element.parentNode.insertBefore(spacer, element);
          }

          return Math.ceil(Math.max(
            body.scrollHeight,
            document.documentElement.scrollHeight,
            body.getBoundingClientRect().bottom + window.scrollY
          ));
        })();
        """
    }
}

/// A small Markdown → HTML converter scoped to the syntax our summaries actually
/// use: a leading YAML front matter block (dropped), ATX headings, paragraphs,
/// ordered/unordered lists, blockquotes, fenced code, horizontal rules, and inline
/// bold/italic/strikethrough/code/links. Unknown syntax degrades to plain text.
///
/// This mirrors TubeFoldKit's Telegraph markdown parsing, with two
/// deliberate differences: the leading `# Title` is kept (the PDF wants it) and the
/// `_Generated with TubeFold_` footer is left in place.
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

    // MARK: - Block parsing

    static func bodyHTML(markdown: String) -> String {
        let source = stripFrontMatter(markdown)
        let lines = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var html: [String] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
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

        while index < lines.count {
            let line = lines[index]
            let stripped = line.trimmingCharacters(in: .whitespaces)

            if stripped.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            // Fenced code block.
            if let fence = firstGroup(fenceRegex, line, 1) {
                flushParagraph()
                index += 1
                var code: [String] = []
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence)
                {
                    code.append(lines[index])
                    index += 1
                }
                index += 1 // consume closing fence
                html.append("<pre><code>\(escape(code.joined(separator: "\n")))</code></pre>")
                continue
            }

            // ATX heading (# … ######).
            if let m = match(headingRegex, line) {
                flushParagraph()
                let hashes = group(m, line, 1)
                let level = min(max(hashes.count, 1), 6)
                let text = group(m, line, 2).trimmingCharacters(in: .whitespaces)
                html.append("<h\(level)>\(inlineHTML(text))</h\(level)>")
                index += 1
                continue
            }

            // Horizontal rule.
            if match(hrRegex, line) != nil {
                flushParagraph()
                html.append("<hr>")
                index += 1
                continue
            }

            // Unordered list.
            if match(ulRegex, line) != nil {
                flushParagraph()
                var items: [String] = []
                while index < lines.count, let m = match(ulRegex, lines[index]) {
                    items
                        .append(
                            "<li>\(inlineHTML(group(m, lines[index], 1).trimmingCharacters(in: .whitespaces)))</li>",
                        )
                    index += 1
                }
                html.append("<ul>\(items.joined())</ul>")
                continue
            }

            // Ordered list.
            if match(olRegex, line) != nil {
                flushParagraph()
                var items: [String] = []
                while index < lines.count, let m = match(olRegex, lines[index]) {
                    items
                        .append(
                            "<li>\(inlineHTML(group(m, lines[index], 1).trimmingCharacters(in: .whitespaces)))</li>",
                        )
                    index += 1
                }
                html.append("<ol>\(items.joined())</ol>")
                continue
            }

            // Blockquote.
            if match(blockquoteRegex, line) != nil {
                flushParagraph()
                var quote: [String] = []
                while index < lines.count, let m = match(blockquoteRegex, lines[index]) {
                    quote.append(group(m, lines[index], 1).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                let text = quote.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                html.append("<blockquote>\(inlineHTML(text))</blockquote>")
                continue
            }

            paragraph.append(line)
            index += 1
        }

        flushParagraph()
        return html.joined(separator: "\n")
    }

    /// Drop a leading `---`-delimited YAML front-matter block, if present.
    private static func stripFrontMatter(_ markdown: String) -> String {
        var text = markdown
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
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
        let ns = head as NSString
        guard let m = leadingTitleRegex.firstMatch(
            in: head,
            options: [.anchored],
            range: NSRange(location: 0, length: ns.length),
        ) else {
            return markdown
        }
        let rest = ns.substring(from: m.range.length)
        return String(rest.drop(while: { $0 == "\n" }))
    }

    /// Drop a trailing `_Generated with [TubeFold](…)_` credit footer (we render a
    /// richer one). Mirrors `SummaryText.stripTubeFoldFooter`.
    private static func stripFooter(_ markdown: String) -> String {
        let ns = markdown as NSString
        let range = NSRange(location: 0, length: ns.length)
        return footerRegex.stringByReplacingMatches(in: markdown, options: [], range: range, withTemplate: "")
    }

    /// Read a single scalar from the leading YAML front matter. Values are written
    /// by the pipeline as JSON scalars (strings quoted), so a quoted value is
    /// JSON-decoded. Mirrors `telegraph.front_matter_value`. Returns "" if absent.
    static func frontMatterValue(_ markdown: String, _ key: String) -> String {
        var text = markdown
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
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
        if text.isEmpty { return "" }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        var best: (kind: Inline, match: NSTextCheckingResult)?
        for (kind, regex) in inlinePatterns {
            guard let m = regex.firstMatch(in: text, options: [], range: full) else { continue }
            if best == nil || m.range.location < best!.match.range.location {
                best = (kind, m)
            }
        }

        guard let (kind, m) = best else { return escape(text) }

        var out = ""
        if m.range.location > 0 {
            out += escape(ns.substring(with: NSRange(location: 0, length: m.range.location)))
        }

        switch kind {
        case .code:
            out += "<code>\(escape(firstNonEmptyGroup(m, ns)))</code>"
        case .link:
            let label = ns.substring(with: m.range(at: 1))
            let href = ns.substring(with: m.range(at: 2))
            out += "<a href=\"\(escapeAttribute(href))\">\(inlineHTML(label))</a>"
        case .bold:
            out += "<strong>\(inlineHTML(firstNonEmptyGroup(m, ns)))</strong>"
        case .italic:
            out += "<em>\(inlineHTML(firstNonEmptyGroup(m, ns)))</em>"
        case .strike:
            out += "<s>\(inlineHTML(firstNonEmptyGroup(m, ns)))</s>"
        }

        let restStart = m.range.location + m.range.length
        if restStart < ns.length {
            out += inlineHTML(ns.substring(from: restStart))
        }
        return out
    }

    // MARK: - Regex helpers

    private static let headingRegex = regex("^(#{1,6})\\s+(.*)$")
    private static let hrRegex = regex("^\\s*([-*_])\\1{2,}\\s*$")
    private static let ulRegex = regex("^\\s*[-*+]\\s+(.*)$")
    private static let olRegex = regex("^\\s*\\d+[.)]\\s+(.*)$")
    private static let blockquoteRegex = regex("^\\s*>\\s?(.*)$")
    private static let fenceRegex = regex("^\\s*(```|~~~)")

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are static and known-valid; a bad one is a programmer error.
        try! NSRegularExpression(pattern: pattern)
    }

    private static func match(_ regex: NSRegularExpression, _ line: String) -> NSTextCheckingResult? {
        let ns = line as NSString
        return regex.firstMatch(in: line, options: [], range: NSRange(location: 0, length: ns.length))
    }

    private static func group(_ match: NSTextCheckingResult, _ line: String, _ index: Int) -> String {
        let range = match.range(at: index)
        guard range.location != NSNotFound else { return "" }
        return (line as NSString).substring(with: range)
    }

    /// First capture group of `regex` in `line`, or nil if no match.
    private static func firstGroup(_ regex: NSRegularExpression, _ line: String, _ index: Int) -> String? {
        guard let m = match(regex, line) else { return nil }
        let range = m.range(at: index)
        guard range.location != NSNotFound else { return nil }
        return (line as NSString).substring(with: range)
    }

    /// Picks the first non-nil capture group — the
    /// first non-empty alternation group (bold/italic each have two).
    private static func firstNonEmptyGroup(_ match: NSTextCheckingResult, _ ns: NSString) -> String {
        for i in 1 ..< match.numberOfRanges {
            let range = match.range(at: i)
            if range.location != NSNotFound {
                return ns.substring(with: range)
            }
        }
        return ""
    }

    // MARK: - HTML escaping

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeAttribute(_ text: String) -> String {
        escape(text).replacingOccurrences(of: "\"", with: "&quot;")
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
