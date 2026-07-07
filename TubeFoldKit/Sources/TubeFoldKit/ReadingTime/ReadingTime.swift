import Foundation

/// Estimate how long a summary takes to read.
///
/// A port of the `readtime` package's algorithm
/// (https://github.com/alanhamlett/readtime), which itself mirrors Medium's
/// read-time formula:
///
/// - average reading speed of `defaultWPM` (265) words per minute,
/// - words counted by splitting on `\W+` (matching `readtime` exactly, empty
///   tokens included),
/// - inline images add time that decays from 12s for the first image down to
///   a 3s-per-image floor,
/// - the final read time is `max(1, ceil(seconds / 60))` minutes.
///
/// The summary's visible text is extracted by reusing `TelegraphMarkdown`'s
/// parser, so link URLs are dropped and only their labels are counted — the
/// same behaviour `readtime`'s HTML parser has.
public enum ReadingTime {
    public static let defaultWPM = 265

    nonisolated(unsafe) private static let wordDelimiter = /\W+/

    /// Reading time of plain text in seconds (`readtime.read_time_as_seconds`).
    public static func readTimeAsSeconds(_ text: String, images: Int = 0, wpm: Int = defaultWPM) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty leading/trailing tokens count as words (readtime does the same).
        let numWords = trimmed.split(separator: wordDelimiter, omittingEmptySubsequences: false).count

        var seconds = Int((Double(numWords) / Double(wpm) * 60).rounded(.up))

        var delta = 12
        for _ in 0 ..< max(0, images) {
            seconds += delta
            if delta > 3 {
                delta -= 1
            }
        }
        return seconds
    }

    private static func collectText(
        _ nodes: [TelegraphNode],
        into parts: inout [String],
        imageCount: inout Int
    ) {
        for node in nodes {
            switch node {
            case let .text(text):
                parts.append(text)
            case let .element(tag, _, children):
                if tag == "img" {
                    imageCount += 1
                }
                collectText(children, into: &parts, imageCount: &imageCount)
            }
        }
    }

    static func markdownPlainText(_ summaryMarkdown: String) -> (text: String, images: Int) {
        let body = TelegraphMarkdown.stripFrontMatter(summaryMarkdown)
        var parts: [String] = []
        var images = 0
        collectText(TelegraphMarkdown.markdownToNodes(body), into: &parts, imageCount: &images)
        let plainText = parts.joined(separator: " ")
            .replacing(/\s+/, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (plainText, images)
    }

    public static func readingSeconds(forMarkdown summaryMarkdown: String, wpm: Int = defaultWPM) -> Int {
        let (text, images) = markdownPlainText(summaryMarkdown)
        return readTimeAsSeconds(text, images: images, wpm: wpm)
    }

    /// Whole-minute read time of a summary's Markdown, never below 1.
    public static func readingMinutes(forMarkdown summaryMarkdown: String, wpm: Int = defaultWPM) -> Int {
        let seconds = readingSeconds(forMarkdown: summaryMarkdown, wpm: wpm)
        return max(1, Int((Double(seconds) / 60).rounded(.up)))
    }

    /// Human label, e.g. `"5 min read"` (matches `readtime`'s repr).
    public static func label(minutes: Int) -> String {
        "\(minutes) min read"
    }
}
