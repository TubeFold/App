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
        let script = Self.paginationScript(pageHeight: Self.paperSize.height)
        webView.evaluateJavaScript(script) { [weak self] value, error in
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
            // Same source-page → output-page mapping the drawing above applied.
            let transform = CGAffineTransform(translationX: 0, y: yOffset)
                .scaledBy(x: scale, y: scale)
                .translatedBy(x: -sourceBox.minX, y: -sourceBox.minY)
            addLinkAnnotations(annotations, transform: transform, context: context, mediaBox: mediaBox)
            context.endPDFPage()
        }

        context.closePDF()
        return outputData as Data
    }

    private static func addLinkAnnotations(
        _ annotations: [PDFAnnotation],
        transform: CGAffineTransform,
        context: CGContext,
        mediaBox: CGRect,
    ) {
        for annotation in annotations {
            guard let url = annotation.url else { continue }
            let targetBounds = annotation.bounds.applying(transform)
            let clipped = targetBounds.intersection(mediaBox)
            guard !clipped.isNull, !clipped.isEmpty else { continue }
            context.setURL(url as CFURL, for: clipped)
        }
    }

    private static func paginationScript(pageHeight: CGFloat) -> String {
        paginationScriptTemplate.replacingOccurrences(
            of: "__PAGE_HEIGHT__",
            with: String(format: "%.3f", pageHeight),
        )
    }

    private static let paginationScriptTemplate = """
    (() => {
      const pageHeight = __PAGE_HEIGHT__;
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
