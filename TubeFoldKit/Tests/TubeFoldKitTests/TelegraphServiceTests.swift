import Foundation
import Testing

@testable import TubeFoldKit

// MARK: - Fake Telegraph API

private final class FakeTelegraph: @unchecked Sendable {
    private let lock = NSLock()
    private var _accountCount = 0
    private var _createPageCount = 0
    private var _editPageCount = 0
    private var _pageListCalls: [[String: String]] = []
    private var _createPageTokens: [String] = []

    var accountCount: Int { lock.withLock { _accountCount } }
    var createPageCount: Int { lock.withLock { _createPageCount } }
    var editPageCount: Int { lock.withLock { _editPageCount } }
    var pageListCalls: [[String: String]] { lock.withLock { _pageListCalls } }
    var createPageTokens: [String] { lock.withLock { _createPageTokens } }

    /// Pages served by `getPageList`, sliced by the requested offset/limit.
    var publishedPages: [[String: Any]] = []

    func handle(method: String, params: [String: String]) -> [String: Any] {
        if method == "getPageList" {
            lock.withLock { _pageListCalls.append(params) }
            guard params["access_token"] == "token-123" else {
                return ["ok": false, "error": "ACCESS_TOKEN_INVALID"]
            }
            let offset = Int(params["offset"] ?? "0") ?? 0
            let limit = Int(params["limit"] ?? "50") ?? 50
            let slice = publishedPages.dropFirst(offset).prefix(limit)
            return ["ok": true, "result": [
                "total_count": publishedPages.count,
                "pages": Array(slice),
            ]]
        }
        if method == "createAccount" {
            let count = lock.withLock { () -> Int in
                _accountCount += 1
                return _accountCount
            }
            // First account keeps the token the getPageList stub expects;
            // later ones get distinct tokens so account swaps are observable.
            return ["ok": true, "result": [
                "access_token": count == 1 ? "token-123" : "token-\(count)",
                "short_name": params["short_name"] ?? "",
            ]]
        }
        if method == "createPage" {
            lock.withLock {
                _createPageCount += 1
                _createPageTokens.append(params["access_token"] ?? "")
            }
            return ["ok": true, "result": [
                "url": "https://telegra.ph/Test-Page-01",
                "path": "Test-Page-01",
            ]]
        }
        if method.hasPrefix("editPage/") {
            lock.withLock { _editPageCount += 1 }
            return ["ok": true, "result": [
                "url": "https://telegra.ph/Test-Page-01",
                "path": "Test-Page-01",
            ]]
        }
        return ["ok": false, "error": "unknown method \(method)"]
    }
}

private func makeDataDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("tubefoldkit-telegraph-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func insertReadyVideo(
    _ store: VideoStore,
    summary: String,
    videoID: String = "dQw4w9WgXcQ"
) async throws -> String {
    let (_, id, jobID) = try await store.createOrReuse(SummaryRequest(
        videoID: videoID,
        url: "https://www.youtube.com/watch?v=\(videoID)",
        title: "Test Video",
        channelName: "Test Channel",
        durationSeconds: 100
    ))
    try await store.markReady(
        videoID: id, jobID: jobID!,
        transcriptPath: "/tmp/transcript.txt", summaryPath: "/tmp/summary.md",
        summaryMarkdown: summary
    )
    return id
}

// MARK: - Article content

@Suite struct TelegraphArticleTests {
    private func rendered(_ nodes: [TelegraphNode]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(nodes)) ?? Data(), as: UTF8.self)
    }

    @Test func bodyStartsImmediatelyNoTopHeader() {
        let content = TelegraphArticle.buildContent(summaryMarkdown: "# Summary\n\nBody.")
        #expect(content[0] == .element(tag: "p", children: [.text("Body.")]))
        #expect(!rendered(content).contains("read summary"))
    }

    @Test func creditFooterCarriesWatchAndReadTime() throws {
        let content = TelegraphArticle.buildContent(summaryMarkdown: "# Summary\n\nBody.", durationSeconds: 660)
        #expect(content[content.count - 2] == .element(tag: "hr"))

        guard case let .element("p", _, footerChildren) = content.last,
              case let .element("em", _, emChildren) = footerChildren.first else {
            Issue.record("footer shape unexpected")
            return
        }
        #expect(emChildren[1] == .element(
            tag: "a",
            attrs: ["href": "https://tubefold.github.io/"],
            children: [.text("TubeFold")]
        ))
        guard case let .text(note) = emChildren[2] else {
            Issue.record("note missing")
            return
        }
        #expect(note.contains("11 min watching"))
        #expect(note.contains("→"))
        #expect(note.contains("min reading"))
    }

    @Test func creditFooterCarriesModelFromFrontMatter() {
        let md = "---\nmodel: \"codex gpt-5.4-mini (effort: medium)\"\n---\n\n# Summary\n\nBody."
        let content = TelegraphArticle.buildContent(summaryMarkdown: md)
        let output = rendered(content)
        #expect(output.contains("Summarized by codex gpt-5.4-mini (effort: medium)"))
        #expect(output.contains("{\"tag\":\"br\"}"))
    }

    @Test func creditFooterOmitsModelWhenAbsent() {
        let content = TelegraphArticle.buildContent(summaryMarkdown: "# Summary\n\nBody.")
        #expect(!rendered(content).contains("Summarized by"))
    }

    @Test func creditFooterOmitsWatchTimeWhenDurationUnknown() {
        let content = TelegraphArticle.buildContent(summaryMarkdown: "# Summary\n\nBody.")
        let output = rendered(content)
        #expect(!output.contains("watching"))
        #expect(output.contains("min reading"))
    }

    @Test func mdCreditFooterIsStrippedNotDuplicated() {
        let md = "# Summary\n\n## Кратко\n\nText.\n" + SummaryText.footerMarkdown()
        let content = TelegraphArticle.buildContent(summaryMarkdown: md)
        let output = rendered(content)
        #expect(output.components(separatedBy: "Generated with").count - 1 == 1)
        #expect(content[0] == .element(tag: "h3", children: [.text("Кратко")]))
    }

    @Test func leadingTitleIsDroppedFromBody() {
        let content = TelegraphArticle.buildContent(summaryMarkdown: "# Switch 2 - После года\n\n## Кратко\n\nText.")
        #expect(content[0] == .element(tag: "h3", children: [.text("Кратко")]))
        let body = Array(content.dropLast(2))
        #expect(!rendered(body).contains("Switch 2"))
    }

    @Test func contentTruncatedUnder64KB() {
        let huge = (0 ..< 400)
            .map { "Paragraph \($0) " + String(repeating: "word ", count: 200) }
            .joined(separator: "\n\n")
        let content = TelegraphArticle.buildContent(summaryMarkdown: huge)
        #expect(TelegraphNode.serializedByteCount(content) <= TelegraphArticle.maxContentBytes)
        #expect(rendered([content.last!]).contains("truncated"))
    }

    @Test func watchMinutesLabel() {
        #expect(TelegraphArticle.watchMinutesLabel(durationSeconds: 660) == "11 min watching")
        #expect(TelegraphArticle.watchMinutesLabel(durationSeconds: 10) == "1 min watching")
        #expect(TelegraphArticle.watchMinutesLabel(durationSeconds: 0) == nil)
        #expect(TelegraphArticle.watchMinutesLabel(durationSeconds: nil) == nil)
    }
}

// MARK: - Publisher

@Suite struct TelegraphPublisherTests {
    private func makePublisher(dataDir: URL, store: VideoStore, fake: FakeTelegraph) -> TelegraphPublisher {
        TelegraphPublisher(
            dataDirectory: dataDir,
            videoStore: store,
            client: TelegraphClient(requestFn: { method, params in
                fake.handle(method: method, params: params)
            })
        )
    }

    @Test func firstPublishCreatesAccountOnceAndPage() async throws {
        let dataDir = try makeDataDir()
        defer { try? FileManager.default.removeItem(at: dataDir) }
        let store = try VideoStore.inMemory()
        let fake = FakeTelegraph()
        let videoID = try await insertReadyVideo(store, summary: "# Title\n\nBody content here.")

        let result = try await makePublisher(dataDir: dataDir, store: store, fake: fake).publish(videoID: videoID)
        #expect(result.status == "published")
        #expect(result.url == "https://telegra.ph/Test-Page-01")
        #expect(fake.accountCount == 1)
        #expect(fake.createPageCount == 1)
        #expect(FileManager.default.fileExists(atPath: dataDir.appendingPathComponent("telegraph-account.json").path))
    }

    @Test func repeatPublishReusesURLWithoutNewCalls() async throws {
        let dataDir = try makeDataDir()
        defer { try? FileManager.default.removeItem(at: dataDir) }
        let store = try VideoStore.inMemory()
        let fake = FakeTelegraph()
        let videoID = try await insertReadyVideo(store, summary: "# Title\n\nBody content here.")
        let publisher = makePublisher(dataDir: dataDir, store: store, fake: fake)

        _ = try await publisher.publish(videoID: videoID)
        let second = try await publisher.publish(videoID: videoID)
        #expect(second.status == "reused")
        #expect(fake.createPageCount == 1)
        #expect(fake.accountCount == 1)
        #expect(fake.editPageCount == 0)
    }

    @Test func accountTokenReusedAcrossVideos() async throws {
        let dataDir = try makeDataDir()
        defer { try? FileManager.default.removeItem(at: dataDir) }
        let store = try VideoStore.inMemory()
        let fake = FakeTelegraph()
        let first = try await insertReadyVideo(store, summary: "# One\n\nBody one.", videoID: "dQw4w9WgXcQ")
        let second = try await insertReadyVideo(store, summary: "# Two\n\nBody two.", videoID: "9bZkp7q19f0")
        let publisher = makePublisher(dataDir: dataDir, store: store, fake: fake)

        _ = try await publisher.publish(videoID: first)
        _ = try await publisher.publish(videoID: second)
        #expect(fake.accountCount == 1)
        #expect(fake.createPageCount == 2)
    }

    @Test func regeneratedSummaryUpdatesSamePageViaEditPage() async throws {
        let dataDir = try makeDataDir()
        defer { try? FileManager.default.removeItem(at: dataDir) }
        let store = try VideoStore.inMemory()
        let fake = FakeTelegraph()
        let videoID = try await insertReadyVideo(store, summary: "# Title\n\nOriginal body.")
        let publisher = makePublisher(dataDir: dataDir, store: store, fake: fake)

        let first = try await publisher.publish(videoID: videoID)
        try await store.markReady(
            videoID: videoID, jobID: UUID().uuidString,
            transcriptPath: "/tmp/transcript.txt", summaryPath: "/tmp/summary.md",
            summaryMarkdown: "# Title\n\nUpdated body with new content."
        )
        let second = try await publisher.publish(videoID: videoID)
        #expect(second.status == "updated")
        #expect(second.url == first.url)
        #expect(fake.createPageCount == 1)
        #expect(fake.editPageCount == 1)
    }

    @Test func publishWithoutSummaryThrows() async throws {
        let dataDir = try makeDataDir()
        defer { try? FileManager.default.removeItem(at: dataDir) }
        let store = try VideoStore.inMemory()
        let fake = FakeTelegraph()
        let (_, videoID, _) = try await store.createOrReuse(SummaryRequest(
            videoID: "dQw4w9WgXcQ", url: "https://youtu.be/dQw4w9WgXcQ", title: "X"
        ))

        await #expect(throws: TelegraphError.noSummaryToPublish) {
            _ = try await makePublisher(dataDir: dataDir, store: store, fake: fake).publish(videoID: videoID)
        }
    }

    @Test func listPagesWithoutAccountReturnsEmptyWithoutAPICalls() async throws {
        let dataDir = try makeDataDir()
        defer { try? FileManager.default.removeItem(at: dataDir) }
        let fake = FakeTelegraph()
        let publisher = makePublisher(dataDir: dataDir, store: try VideoStore.inMemory(), fake: fake)

        let pages = try await publisher.listPages()
        #expect(pages.isEmpty)
        #expect(fake.pageListCalls.isEmpty)
        #expect(fake.accountCount == 0)
        #expect(publisher.accountShortName() == nil)
    }

    @Test func listPagesReturnsPublishedPages() async throws {
        let dataDir = try makeDataDir()
        defer { try? FileManager.default.removeItem(at: dataDir) }
        try TelegraphStore(dataDirectory: dataDir).save(["accessToken": "token-123", "shortName": "yt-brain-1a2b3c4d"])
        let fake = FakeTelegraph()
        fake.publishedPages = [
            ["path": "First-01", "url": "https://telegra.ph/First-01", "title": "First", "views": 7],
            ["path": "Second-02", "url": "https://telegra.ph/Second-02", "title": "Second", "views": 0],
        ]
        let publisher = makePublisher(dataDir: dataDir, store: try VideoStore.inMemory(), fake: fake)

        let pages = try await publisher.listPages()
        #expect(pages == [
            TelegraphPageInfo(path: "First-01", url: "https://telegra.ph/First-01", title: "First", views: 7),
            TelegraphPageInfo(path: "Second-02", url: "https://telegra.ph/Second-02", title: "Second", views: 0),
        ])
        #expect(fake.pageListCalls.count == 1)
        #expect(fake.pageListCalls[0]["offset"] == "0")
        #expect(publisher.accountShortName() == "yt-brain-1a2b3c4d")
    }

    @Test func listPagesPaginatesPastTheAPILimit() async throws {
        let dataDir = try makeDataDir()
        defer { try? FileManager.default.removeItem(at: dataDir) }
        try TelegraphStore(dataDirectory: dataDir).save(["accessToken": "token-123"])
        let fake = FakeTelegraph()
        fake.publishedPages = (0 ..< 250).map { index in
            ["path": "Page-\(index)", "url": "https://telegra.ph/Page-\(index)", "title": "Page \(index)", "views": index]
        }
        let publisher = makePublisher(dataDir: dataDir, store: try VideoStore.inMemory(), fake: fake)

        let pages = try await publisher.listPages()
        #expect(pages.count == 250)
        #expect(pages.last?.path == "Page-249")
        #expect(fake.pageListCalls.count == 2)
        #expect(fake.pageListCalls[1]["offset"] == "200")
    }

    @Test func newAccountsUseTheTubefoldPrefix() {
        let name = TelegraphPublisher.makeShortName()
        #expect(name.hasPrefix("tubefold-"))
        #expect(name.count == "tubefold-".count + 8)
    }

    @Test func regenerateAccountSwapsTokenArchivesOldAndForgetsCachedPages() async throws {
        let dataDir = try makeDataDir()
        defer { try? FileManager.default.removeItem(at: dataDir) }
        let store = try VideoStore.inMemory()
        let fake = FakeTelegraph()
        let videoID = try await insertReadyVideo(store, summary: "# Title\n\nBody content here.")
        let publisher = makePublisher(dataDir: dataDir, store: store, fake: fake)

        _ = try await publisher.publish(videoID: videoID)
        let newName = try await publisher.regenerateAccount()
        #expect(newName.hasPrefix("tubefold-"))
        #expect(publisher.accountShortName() == newName)
        #expect(fake.accountCount == 2)

        // Old credentials are archived, not lost.
        let state = TelegraphStore(dataDirectory: dataDir).load()
        let previous = state["previousAccounts"] as? [[String: Any]]
        #expect(previous?.count == 1)
        #expect(previous?.first?["accessToken"] as? String == "token-123")

        // The cached page was forgotten, so re-publishing creates a fresh
        // page with the new token instead of editing the old account's page.
        let republished = try await publisher.publish(videoID: videoID)
        #expect(republished.status == "published")
        #expect(fake.editPageCount == 0)
        #expect(fake.createPageTokens == ["token-123", "token-2"])
    }

    @Test func apiErrorSurfaces() async throws {
        let dataDir = try makeDataDir()
        defer { try? FileManager.default.removeItem(at: dataDir) }
        let store = try VideoStore.inMemory()
        let videoID = try await insertReadyVideo(store, summary: "# Title\n\nBody content here.")
        let publisher = TelegraphPublisher(
            dataDirectory: dataDir,
            videoStore: store,
            client: TelegraphClient(requestFn: { _, _ in ["ok": false, "error": "FLOOD_WAIT"] })
        )
        await #expect(throws: TelegraphError.api("FLOOD_WAIT")) {
            _ = try await publisher.publish(videoID: videoID)
        }
    }
}
