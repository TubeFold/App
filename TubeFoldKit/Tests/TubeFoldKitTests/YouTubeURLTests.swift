import Testing

@testable import TubeFoldKit

// URL/video-id parsing across the supported YouTube URL shapes.
@Suite struct YouTubeURLTests {
    @Test func watchURL() throws {
        #expect(try YouTubeURL.parseVideoID("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s") == "dQw4w9WgXcQ")
    }

    @Test func shortURL() throws {
        #expect(try YouTubeURL.parseVideoID("https://youtu.be/dQw4w9WgXcQ?si=test") == "dQw4w9WgXcQ")
    }

    @Test func embedURL() throws {
        #expect(try YouTubeURL.parseVideoID("https://youtube.com/embed/dQw4w9WgXcQ") == "dQw4w9WgXcQ")
    }

    @Test func shortsURL() throws {
        #expect(try YouTubeURL.parseVideoID("https://youtube.com/shorts/dQw4w9WgXcQ") == "dQw4w9WgXcQ")
    }

    @Test func liveURL() throws {
        #expect(try YouTubeURL.parseVideoID("https://www.youtube.com/live/dQw4w9WgXcQ") == "dQw4w9WgXcQ")
    }

    @Test func schemelessURL() throws {
        #expect(try YouTubeURL.parseVideoID("youtu.be/dQw4w9WgXcQ") == "dQw4w9WgXcQ")
        #expect(try YouTubeURL.parseVideoID("m.youtube.com/watch?v=dQw4w9WgXcQ") == "dQw4w9WgXcQ")
    }

    @Test func plainVideoID() throws {
        #expect(try YouTubeURL.parseVideoID("dQw4w9WgXcQ") == "dQw4w9WgXcQ")
    }

    @Test func placeholderVideoIDIsRejected() {
        #expect(throws: YouTubeURLError.unsupportedURL) {
            try YouTubeURL.parseVideoID("VIDEO_ID")
        }
    }

    @Test func nonYouTubeHostIsRejected() {
        #expect(throws: YouTubeURLError.unsupportedURL) {
            try YouTubeURL.parseVideoID("https://vimeo.com/12345678901")
        }
    }

    @Test func normalizedURL() throws {
        #expect(try YouTubeURL.normalize("https://youtu.be/dQw4w9WgXcQ") == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    }

    @Test func thumbnailURL() {
        #expect(YouTubeURL.thumbnailURL(videoID: "dQw4w9WgXcQ") == "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg")
        #expect(YouTubeURL.thumbnailURL(videoID: "  ") == "")
    }
}
