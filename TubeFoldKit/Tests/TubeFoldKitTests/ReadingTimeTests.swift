import Testing

@testable import TubeFoldKit

// Read-time math: WPM rounding, image decay, markdown text extraction.
@Suite struct ReadingTimeTests {
    @Test func wpmSecondsMath() {
        // 2 words at 2 wpm -> exactly one minute.
        #expect(ReadingTime.readTimeAsSeconds("hello world", wpm: 2) == 60)
        // ceil rounding: 3 words at 2 wpm -> 90 seconds.
        #expect(ReadingTime.readTimeAsSeconds("a b c", wpm: 2) == 90)
    }

    @Test func defaultWPM() {
        #expect(ReadingTime.defaultWPM == 265)
        let words = Array(repeating: "word", count: 265).joined(separator: " ")
        #expect(ReadingTime.readTimeAsSeconds(words) == 60)
    }

    @Test func imageTimeDecaysToThreeSecondFloor() {
        let base = ReadingTime.readTimeAsSeconds("x", images: 0)
        // 11 images: 12,11,10,9,8,7,6,5,4,3 then a 3s floor = 78 extra seconds.
        #expect(ReadingTime.readTimeAsSeconds("x", images: 11) - base == 78)
        // A single image adds the full 12 seconds.
        #expect(ReadingTime.readTimeAsSeconds("x", images: 1) - base == 12)
    }

    @Test func minutesNeverBelowOne() {
        #expect(ReadingTime.readingMinutes(forMarkdown: "") == 1)
        #expect(ReadingTime.readingMinutes(forMarkdown: "# Title\n\nA short body.") == 1)
    }

    @Test func longerSummaryTakesMoreMinutes() {
        let body = "# Title\n\n" + Array(repeating: "word", count: 1200).joined(separator: " ")
        #expect(ReadingTime.readingMinutes(forMarkdown: body) > 1)
    }

    @Test func labelFormat() {
        #expect(ReadingTime.label(minutes: 1) == "1 min read")
        #expect(ReadingTime.label(minutes: 7) == "7 min read")
    }

    @Test func linkURLsAreNotCounted() {
        let withLink = "Read this [guide](https://example.com/very/long/path/with/many/words)."
        let withoutLink = "Read this guide."
        #expect(ReadingTime.readingSeconds(forMarkdown: withLink) == ReadingTime.readingSeconds(forMarkdown: withoutLink))
    }

    @Test func frontMatterIsIgnored() {
        let front = "---\ntitle: \"X\"\nurl: \"https://youtu.be/abc\"\n---\n\nBody text here."
        #expect(ReadingTime.readingSeconds(forMarkdown: front) == ReadingTime.readingSeconds(forMarkdown: "Body text here."))
    }
}
