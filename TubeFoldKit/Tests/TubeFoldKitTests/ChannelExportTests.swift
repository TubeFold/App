import Foundation
import Testing

@testable import TubeFoldKit

/// Channel-URL parsing, the generic `browse` payload reader, and the bulk
/// transcript export (driven end to end through a stub transport).
@Suite struct ChannelURLTests {
    @Test func handleURLWithTab() throws {
        let reference = try YouTubeChannelURL.parse("https://www.youtube.com/@Ro.Man./videos")
        #expect(reference.target == .vanityURL("https://www.youtube.com/@Ro.Man."))
        #expect(reference.tab == .videos)
        #expect(reference.label == "@Ro.Man.")
    }

    @Test func handleURLWithoutTab() throws {
        let reference = try YouTubeChannelURL.parse("youtube.com/@Ro.Man.")
        #expect(reference.target == .vanityURL("https://www.youtube.com/@Ro.Man."))
        #expect(reference.tab == nil)
    }

    @Test func bareHandle() throws {
        #expect(try YouTubeChannelURL.parse("@handle").target == .vanityURL("https://www.youtube.com/@handle"))
    }

    @Test func channelIDURLAndBareID() throws {
        let id = "UC9TQYeaZKf48tRIwMt6jFGw"
        #expect(try YouTubeChannelURL.parse("https://www.youtube.com/channel/\(id)/streams").tab == .streams)
        #expect(try YouTubeChannelURL.parse("https://www.youtube.com/channel/\(id)").target == .browseID(id))
        #expect(try YouTubeChannelURL.parse(id).target == .browseID(id))
    }

    @Test func legacyVanityPaths() throws {
        #expect(try YouTubeChannelURL.parse("https://www.youtube.com/c/Name/videos").target
            == .vanityURL("https://www.youtube.com/c/Name"))
        #expect(try YouTubeChannelURL.parse("https://www.youtube.com/user/Name").target
            == .vanityURL("https://www.youtube.com/user/Name"))
    }

    @Test func videoInputsAreNotChannels() {
        #expect(!YouTubeChannelURL.isChannelInput("https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        #expect(!YouTubeChannelURL.isChannelInput("https://youtu.be/dQw4w9WgXcQ"))
        #expect(!YouTubeChannelURL.isChannelInput("dQw4w9WgXcQ"))
        #expect(!YouTubeChannelURL.isChannelInput("https://vimeo.com/@someone"))
    }

    @Test func channelInputsAreNotVideos() {
        #expect(throws: YouTubeURLError.unsupportedURL) {
            try YouTubeURL.parseVideoID("https://www.youtube.com/@Ro.Man./videos")
        }
    }
}

// MARK: - Browse payload reading

@Suite struct ChannelBrowseParserTests {
    /// Current web shape: `richItemRenderer` → `lockupViewModel`, with the
    /// grid's trailing continuation item plus decoy tokens elsewhere.
    private func gridPage(withContinuation: Bool) -> [String: Any] {
        func item(_ id: String, _ title: String) -> [String: Any] {
            [
                "richItemRenderer": [
                    "content": [
                        "lockupViewModel": [
                            "contentId": id,
                            "contentType": "LOCKUP_CONTENT_TYPE_VIDEO",
                            "metadata": ["lockupMetadataViewModel": ["title": ["content": title]]],
                            // A menu command repeating the same id — must not
                            // produce a second entry.
                            "menu": ["addToPlaylistCommand": ["videoId": id]],
                        ],
                    ],
                ],
            ]
        }
        var contents: [Any] = [item("aaaaaaaaaaa", "First"), item("bbbbbbbbbbb", "Second")]
        if withContinuation {
            contents.append([
                "continuationItemRenderer": [
                    "continuationEndpoint": ["continuationCommand": ["token": "NEXT"]],
                ],
            ])
        }
        return [
            "metadata": ["channelMetadataRenderer": ["title": "Test Channel"]],
            "contents": ["twoColumnBrowseResultsRenderer": ["tabs": [
                ["tabRenderer": [
                    "selected": false,
                    "endpoint": ["commandMetadata": ["webCommandMetadata": ["url": "/@test/featured"]]],
                ]],
                ["tabRenderer": [
                    "selected": true,
                    "endpoint": ["commandMetadata": ["webCommandMetadata": ["url": "/@test/videos"]]],
                    "content": ["richGridRenderer": [
                        "contents": contents,
                        // Decoy: a sort-chip continuation that loads a filtered
                        // grid, not the next page.
                        "header": ["chipBarViewModel": ["chips": [
                            ["chipViewModel": ["tapCommand": ["continuationCommand": ["token": "CHIP"]]]],
                        ]]],
                    ]],
                ]],
            ]]],
            // Decoy: the description panel's own continuation.
            "header": ["panel": ["contents": [
                ["continuationItemRenderer": ["continuationEndpoint": [
                    "continuationCommand": ["token": "PANEL"],
                ]]],
            ]]],
        ]
    }

    @Test func readsEntriesAndTheGridContinuation() {
        let page = ChannelBrowseParser.page(in: gridPage(withContinuation: true))
        #expect(page.entries.map(\.videoID) == ["aaaaaaaaaaa", "bbbbbbbbbbb"])
        #expect(page.entries.map(\.title) == ["First", "Second"])
        #expect(page.continuation == "NEXT")
    }

    @Test func lastPageHasNoContinuation() {
        #expect(ChannelBrowseParser.page(in: gridPage(withContinuation: false)).continuation == nil)
    }

    @Test func readsSelectedTabAndChannelTitle() {
        let page = gridPage(withContinuation: true)
        #expect(ChannelBrowseParser.selectedTabSlug(in: page) == "videos")
        #expect(ChannelBrowseParser.channelTitle(in: page) == "Test Channel")
    }

    @Test func readsContinuationResponseShape() {
        let payload: [String: Any] = ["onResponseReceivedActions": [
            ["appendContinuationItemsAction": ["continuationItems": [
                ["richItemRenderer": ["content": ["lockupViewModel": [
                    "contentId": "ccccccccccc",
                    "contentType": "LOCKUP_CONTENT_TYPE_VIDEO",
                    "metadata": ["lockupMetadataViewModel": ["title": ["content": "Third"]]],
                ]]]],
                ["continuationItemRenderer": ["continuationEndpoint": [
                    "continuationCommand": ["token": "MORE"],
                ]]],
            ]]],
        ]]
        let page = ChannelBrowseParser.page(in: payload)
        #expect(page.entries == [ChannelVideoEntry(videoID: "ccccccccccc", title: "Third")])
        #expect(page.continuation == "MORE")
    }

    @Test func readsShortsAndLegacyShapes() {
        let payload: [String: Any] = ["contents": [
            ["shortsLockupViewModel": [
                "onTap": ["innertubeCommand": ["reelWatchEndpoint": ["videoId": "ddddddddddd"]]],
                "overlayMetadata": ["primaryText": ["content": "A short"]],
            ]],
            ["gridVideoRenderer": [
                "videoId": "eeeeeeeeeee",
                "title": ["runs": [["text": "Legacy "], ["text": "video"]]],
            ]],
        ]]
        let page = ChannelBrowseParser.page(in: payload)
        #expect(page.entries == [
            ChannelVideoEntry(videoID: "ddddddddddd", title: "A short"),
            ChannelVideoEntry(videoID: "eeeeeeeeeee", title: "Legacy video"),
        ])
    }
}

// MARK: - Transcript document

@Suite struct TranscriptDocumentTests {
    private let metadata = VideoMetadata(
        videoID: "dQw4w9WgXcQ",
        title: "Never Gonna Give You Up",
        channel: "Rick Astley",
        durationSeconds: 213,
        publishedAt: "2009-10-24",
        url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
    )
    private let transcript = TranscriptResult(
        text: "we're no strangers to love",
        language: "English",
        languageCode: "en",
        isGenerated: true
    )

    @Test func publishDateLeadsFrontMatterAndHeader() {
        let markdown = TranscriptDocument.markdown(metadata: metadata, transcript: transcript)
        #expect(markdown.hasPrefix("---\n"))
        #expect(markdown.contains("published_at: \"2009-10-24\""))
        #expect(markdown.contains("type: \"tubefold-transcript\""))
        #expect(markdown.contains("**Published:** 2009-10-24"))
        #expect(markdown.contains("# Never Gonna Give You Up"))
        #expect(markdown.contains("we're no strangers to love"))
    }

    @Test func filenameStemIsDatePrefixed() {
        #expect(TranscriptDocument.filenameStem(publishedAt: "2009-10-24", title: "Title") == "2009-10-24 — Title")
        #expect(TranscriptDocument.filenameStem(publishedAt: "", title: "Title") == "undated — Title")
    }

    @Test func existingVideoIDsAreReadBackFromFrontMatter() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tubefold-transcripts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try TranscriptDocument.markdown(metadata: metadata, transcript: transcript)
            .write(to: directory.appendingPathComponent("saved.md"), atomically: true, encoding: .utf8)
        try "not a transcript".write(
            to: directory.appendingPathComponent("other.txt"),
            atomically: true,
            encoding: .utf8
        )

        #expect(TranscriptDocument.existingVideoIDs(in: directory) == ["dQw4w9WgXcQ"])
    }
}

// MARK: - Export

@Suite struct ChannelTranscriptExportTests {
    /// Stub transport: resolve_url → browse (one page) → player → timedtext.
    /// `failingVideoID` is served a captionless player response.
    private static func transport(failingVideoID: String? = nil) -> InnerTubeClient.Transport {
        { request in
            let url = request.url?.absoluteString ?? ""
            let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let json: Any

            if url.contains("resolve_url") {
                json = ["endpoint": ["browseEndpoint": ["browseId": "UCtestchannelidtestchannel"]]]
            } else if url.contains("browse") {
                json = [
                    "metadata": ["channelMetadataRenderer": ["title": "Stub Channel"]],
                    "contents": ["twoColumnBrowseResultsRenderer": ["tabs": [
                        ["tabRenderer": [
                            "selected": true,
                            "endpoint": ["commandMetadata": ["webCommandMetadata": ["url": "/@stub/videos"]]],
                            "content": ["richGridRenderer": ["contents": [
                                ["richItemRenderer": ["content": ["lockupViewModel": [
                                    "contentId": "aaaaaaaaaaa",
                                    "contentType": "LOCKUP_CONTENT_TYPE_VIDEO",
                                    "metadata": ["lockupMetadataViewModel": ["title": ["content": "Newer"]]],
                                ]]]],
                                ["richItemRenderer": ["content": ["lockupViewModel": [
                                    "contentId": "bbbbbbbbbbb",
                                    "contentType": "LOCKUP_CONTENT_TYPE_VIDEO",
                                    "metadata": ["lockupMetadataViewModel": ["title": ["content": "Older"]]],
                                ]]]],
                            ]]],
                        ]],
                    ]]],
                ]
            } else if url.contains("player") {
                let videoID = (body?["videoId"] as? String) ?? ""
                var player: [String: Any] = [
                    "playabilityStatus": ["status": "OK"],
                    "videoDetails": [
                        "videoId": videoID,
                        "title": videoID == "aaaaaaaaaaa" ? "Newer" : "Older",
                        "author": "Stub Channel",
                        "lengthSeconds": "60",
                    ],
                    "microformat": ["playerMicroformatRenderer": [
                        "publishDate": videoID == "aaaaaaaaaaa" ? "2024-05-02" : "2024-05-01",
                    ]],
                ]
                if videoID != failingVideoID {
                    player["captions"] = ["playerCaptionsTracklistRenderer": ["captionTracks": [[
                        "baseUrl": "https://timedtext.test/\(videoID)",
                        "name": ["simpleText": "English (auto-generated)"],
                        "languageCode": "en",
                        "kind": "asr",
                    ]]]]
                }
                json = player
            } else {
                let xml = "<transcript><text start=\"0\">a transcript long enough to pass</text></transcript>"
                return (Data(xml.utf8), HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!)
            }

            let data = try JSONSerialization.data(withJSONObject: json)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tubefold-channel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func exportsOneDatedFilePerVideoPlusIndex() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let exporter = ChannelTranscriptExporter(client: InnerTubeClient(transport: Self.transport()))
        let summary = try await exporter.export(
            reference: YouTubeChannelURL.parse("@stub"),
            options: ChannelExportOptions(outputDirectory: directory, requestDelay: .zero)
        )

        #expect(summary.channelTitle == "Stub Channel")
        #expect(summary.folder.lastPathComponent == "Stub Channel")
        #expect((summary.saved, summary.skipped, summary.failed) == (2, 0, 0))

        let files = try FileManager.default.contentsOfDirectory(atPath: summary.folder.path).sorted()
        #expect(files == ["2024-05-01 — Older.md", "2024-05-02 — Newer.md", "index.md"])

        let saved = try String(contentsOf: summary.folder.appendingPathComponent("2024-05-02 — Newer.md"))
        #expect(saved.contains("published_at: \"2024-05-02\""))
        #expect(saved.contains("a transcript long enough to pass"))

        let index = try String(contentsOf: summary.folder.appendingPathComponent("index.md"))
        #expect(index.contains("# Stub Channel"))
        #expect(index.contains("| 2024-05-02 | [Newer]"))
    }

    @Test func aFailedVideoDoesNotAbortTheRun() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let exporter = ChannelTranscriptExporter(
            client: InnerTubeClient(transport: Self.transport(failingVideoID: "aaaaaaaaaaa"))
        )
        let summary = try await exporter.export(
            reference: YouTubeChannelURL.parse("@stub"),
            options: ChannelExportOptions(outputDirectory: directory, requestDelay: .zero)
        )

        #expect((summary.saved, summary.failed) == (1, 1))
        #expect(summary.items.first?.outcome == .failed(message: InnerTubeError.noTranscript.userMessage))
        let index = try String(contentsOf: summary.folder.appendingPathComponent("index.md"))
        #expect(index.contains("failed — No transcript found for this video"))
    }

    @Test func limitCapsTheListing() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let exporter = ChannelTranscriptExporter(client: InnerTubeClient(transport: Self.transport()))
        let summary = try await exporter.export(
            reference: YouTubeChannelURL.parse("@stub"),
            options: ChannelExportOptions(outputDirectory: directory, limit: 1, requestDelay: .zero)
        )
        #expect(summary.items.count == 1)
        #expect(summary.saved == 1)
    }

    @Test func alreadyExportedVideosAreSkippedOnRerun() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let exporter = ChannelTranscriptExporter(client: InnerTubeClient(transport: Self.transport()))
        let reference = try YouTubeChannelURL.parse("@stub")
        let options = ChannelExportOptions(outputDirectory: directory, requestDelay: .zero)
        _ = try await exporter.export(reference: reference, options: options)
        let rerun = try await exporter.export(reference: reference, options: options)

        #expect((rerun.saved, rerun.skipped) == (0, 2))
        let files = try FileManager.default.contentsOfDirectory(atPath: rerun.folder.path)
        #expect(files.count == 3) // no duplicate " (2)" copies
    }

    @Test func overwriteRewritesExistingVideos() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let exporter = ChannelTranscriptExporter(client: InnerTubeClient(transport: Self.transport()))
        let reference = try YouTubeChannelURL.parse("@stub")
        _ = try await exporter.export(
            reference: reference,
            options: ChannelExportOptions(outputDirectory: directory, requestDelay: .zero)
        )
        let rerun = try await exporter.export(
            reference: reference,
            options: ChannelExportOptions(outputDirectory: directory, skipExisting: false, requestDelay: .zero)
        )

        #expect(rerun.saved == 2)
        // Names collide, so the rewritten copies land beside the originals.
        let files = try FileManager.default.contentsOfDirectory(atPath: rerun.folder.path)
        #expect(files.contains("2024-05-02 — Newer (2).md"))
    }
}
