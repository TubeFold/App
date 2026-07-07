import CryptoKit
import Foundation

/// "Publish to Telegraph".
///
/// Telegraph constraints that shape this module (verified against
/// telegra.ph/api): account creation is free/anonymous and the returned
/// `access_token` is the only credential; `content` is a node array capped at
/// 64 KB; headings are only `h3`/`h4`; pages are public and cannot be
/// deleted, only edited.
public enum TelegraphError: Error, Equatable {
    case unreachable(String)
    case invalidResponse
    case api(String)
    case noSummaryToPublish
    case missingAccessToken
    case missingPageURL

    public var userMessage: String {
        switch self {
        case let .unreachable(detail): "Could not reach Telegraph: \(detail)"
        case .invalidResponse: "Telegraph returned an invalid response."
        case let .api(message): message
        case .noSummaryToPublish: "This video has no summary to publish yet."
        case .missingAccessToken: "Telegraph did not return an access token."
        case .missingPageURL: "Telegraph did not return a page URL."
        }
    }
}

// MARK: - Article content

public enum TelegraphArticle {
    // Telegraph rejects content larger than 64 KB; stay safely under it.
    public static let maxContentBytes = 63_000
    public static let maxTitleLength = 256

    /// Drop trailing nodes until the serialized content fits the cap.
    static func contentWithinLimit(_ content: [TelegraphNode]) -> [TelegraphNode] {
        if TelegraphNode.serializedByteCount(content) <= maxContentBytes {
            return content
        }
        let notice = TelegraphNode.element(tag: "p", children: [
            .element(tag: "em", children: [.text("… (summary truncated to fit Telegraph)")]),
        ])
        var trimmed = content
        while !trimmed.isEmpty {
            trimmed.removeLast()
            let candidate = trimmed + [notice]
            if TelegraphNode.serializedByteCount(candidate) <= maxContentBytes {
                return candidate
            }
        }
        return [notice]
    }

    /// `N min watching` for the video runtime, or `nil` if unknown.
    static func watchMinutesLabel(durationSeconds: Double?) -> String? {
        guard let durationSeconds else { return nil }
        let total = Int(durationSeconds.rounded())
        guard total > 0 else { return nil }
        return "\(max(1, Int((Double(total) / 60).rounded()))) min watching"
    }

    /// Assemble the Telegraph content: the summary body followed by a single
    /// credit footer.
    ///
    /// The body is stripped of its front matter, its leading `# Title`
    /// (Telegraph sets the page title itself) and the `.md` credit footer,
    /// then a richer credit is appended:
    ///
    ///     Generated with TubeFold (11 min watching → 3 min reading)
    ///
    /// The model line comes from the summary's own front matter (set by the
    /// pipeline).
    public static func buildContent(summaryMarkdown: String, durationSeconds: Double? = nil) -> [TelegraphNode] {
        let bodyMarkdown = SummaryText.stripTubeFoldFooter(
            TelegraphMarkdown.stripLeadingTitle(TelegraphMarkdown.stripFrontMatter(summaryMarkdown))
        )
        let body = TelegraphMarkdown.markdownToNodes(bodyMarkdown)

        let readLabel = "\(ReadingTime.readingMinutes(forMarkdown: summaryMarkdown)) min reading"
        let watchLabel = watchMinutesLabel(durationSeconds: durationSeconds)
        let timeNote = watchLabel.map { " (\($0) → \(readLabel))" } ?? " (\(readLabel))"

        var creditChildren: [TelegraphNode] = [
            .text("Generated with "),
            .element(tag: "a", attrs: ["href": SummaryText.projectURL], children: [.text(SummaryText.projectName)]),
            .text(timeNote),
        ]
        // A second, lighter line crediting the model that wrote the summary.
        let model = TelegraphMarkdown.frontMatterValue(summaryMarkdown, key: "model")
        if !model.isEmpty {
            creditChildren.append(.element(tag: "br"))
            creditChildren.append(.text("Summarized by \(model)"))
        }

        let footer = TelegraphNode.element(tag: "p", children: [
            .element(tag: "em", children: creditChildren),
        ])
        return contentWithinLimit(body + [.element(tag: "hr"), footer])
    }
}

// MARK: - API client

/// Thin client for the public Telegraph API. `requestFn` can be injected so
/// tests never touch the network.
public struct TelegraphClient: Sendable {
    public typealias RequestFn = @Sendable (_ method: String, _ params: [String: String]) async throws -> [String: Any]

    public static let apiBaseURL = "https://api.telegra.ph"

    private let requestFn: RequestFn
    private let timeout: TimeInterval

    public init(requestFn: RequestFn? = nil, timeout: TimeInterval = 20) {
        self.timeout = timeout
        self.requestFn = requestFn ?? { method, params in
            try await Self.httpRequest(method: method, params: params, timeout: timeout)
        }
    }

    @Sendable private static func httpRequest(
        method: String,
        params: [String: String],
        timeout: TimeInterval
    ) async throws -> [String: Any] {
        guard let url = URL(string: "\(apiBaseURL)/\(method)") else {
            throw TelegraphError.unreachable("bad URL")
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)

        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw TelegraphError.unreachable(error.localizedDescription)
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: data),
              let payload = parsed as? [String: Any] else {
            throw TelegraphError.invalidResponse
        }
        return payload
    }

    private func call(_ method: String, params: [String: String]) async throws -> [String: Any] {
        let payload = try await requestFn(method, params)
        guard payload["ok"] as? Bool == true else {
            throw TelegraphError.api((payload["error"] as? String) ?? "Unknown Telegraph error")
        }
        return payload["result"] as? [String: Any] ?? [:]
    }

    public func createAccount(
        shortName: String,
        authorName: String = "",
        authorURL: String = ""
    ) async throws -> [String: Any] {
        var params = ["short_name": shortName.isEmpty ? "tubefold" : String(shortName.prefix(32))]
        if !authorName.isEmpty {
            params["author_name"] = String(authorName.prefix(128))
        }
        if !authorURL.isEmpty {
            params["author_url"] = String(authorURL.prefix(512))
        }
        return try await call("createAccount", params: params)
    }

    public func createPage(
        accessToken: String,
        title: String,
        content: [TelegraphNode],
        authorName: String = "",
        authorURL: String = ""
    ) async throws -> [String: Any] {
        let params = try Self.pageParams(
            accessToken: accessToken, title: title, content: content,
            authorName: authorName, authorURL: authorURL
        )
        return try await call("createPage", params: params)
    }

    public func editPage(
        accessToken: String,
        path: String,
        title: String,
        content: [TelegraphNode],
        authorName: String = "",
        authorURL: String = ""
    ) async throws -> [String: Any] {
        var params = try Self.pageParams(
            accessToken: accessToken, title: title, content: content,
            authorName: authorName, authorURL: authorURL
        )
        params["path"] = path
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return try await call("editPage/\(encodedPath)", params: params)
    }

    static func pageParams(
        accessToken: String,
        title: String,
        content: [TelegraphNode],
        authorName: String,
        authorURL: String
    ) throws -> [String: String] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let contentJSON = String(decoding: try encoder.encode(content), as: UTF8.self)
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var params: [String: String] = [
            "access_token": accessToken,
            "title": String((cleanTitle.isEmpty ? "YouTube summary" : cleanTitle).prefix(TelegraphArticle.maxTitleLength)),
            "content": contentJSON,
        ]
        if !authorName.isEmpty {
            params["author_name"] = String(authorName.prefix(128))
        }
        if !authorURL.isEmpty {
            params["author_url"] = String(authorURL.prefix(512))
        }
        return params
    }
}

// MARK: - Persistence + publishing

/// Persists the single anonymous Telegraph account (created once, reused
/// forever) in `telegraph-account.json`.
public struct TelegraphStore: Sendable {
    public let url: URL

    public init(dataDirectory: URL) {
        url = dataDirectory.appendingPathComponent("telegraph-account.json")
    }

    public func load() -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let state = parsed as? [String: Any] else {
            return [:]
        }
        return state
    }

    public func save(_ state: [String: Any]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: state,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try (data + Data("\n".utf8)).write(to: url, options: .atomic)
    }
}

public struct TelegraphPublishResult: Sendable, Equatable {
    public let url: String
    /// `published` (new page), `updated` (regenerated summary, same URL) or
    /// `reused` (unchanged summary, same URL).
    public let status: String
}

/// One article per video (a stable URL): first publish creates the page and
/// caches its URL/path on the video row; a repeat publish with an unchanged
/// summary reopens the same URL; a regenerated summary updates the same page
/// in place via `editPage`.
public struct TelegraphPublisher: Sendable {
    let store: TelegraphStore
    let client: TelegraphClient
    let videoStore: VideoStore

    public init(dataDirectory: URL, videoStore: VideoStore, client: TelegraphClient = TelegraphClient()) {
        store = TelegraphStore(dataDirectory: dataDirectory)
        self.client = client
        self.videoStore = videoStore
    }

    func ensureAccountToken() async throws -> String {
        if let token = store.load()["accessToken"] as? String, !token.isEmpty {
            return token
        }
        let shortName = "yt-brain-\((0 ..< 8).map { _ in "0123456789abcdef".randomElement()! }.map(String.init).joined())"
        let account = try await client.createAccount(shortName: shortName, authorName: "TubeFold")
        guard let token = account["access_token"] as? String, !token.isEmpty else {
            throw TelegraphError.missingAccessToken
        }
        try store.save([
            "accessToken": token,
            "shortName": (account["short_name"] as? String) ?? shortName,
            "createdAt": ISO8601DateFormatter().string(from: Date()),
        ])
        return token
    }

    public func publish(videoID: String) async throws -> TelegraphPublishResult {
        guard let video = try await videoStore.getVideo(id: videoID) else {
            throw TelegraphError.noSummaryToPublish
        }

        var summary = video.summaryMarkdown ?? ""
        if summary.isEmpty, let summaryPath = video.summaryPath {
            summary = (try? String(contentsOfFile: summaryPath, encoding: .utf8)) ?? ""
        }
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TelegraphError.noSummaryToPublish
        }

        let summaryHash = SHA256.hash(data: Data(summary.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        if let cachedURL = video.telegraphURL, !cachedURL.isEmpty,
           let cachedPath = video.telegraphPath, !cachedPath.isEmpty,
           video.telegraphSummaryHash == summaryHash {
            return TelegraphPublishResult(url: cachedURL, status: "reused")
        }

        let token = try await ensureAccountToken()
        let title = video.title ?? video.youtubeVideoID
        let content = TelegraphArticle.buildContent(
            summaryMarkdown: summary,
            durationSeconds: video.durationSeconds
        )
        let channel = video.channelName ?? ""
        let videoURL = video.canonicalURL

        if let cachedURL = video.telegraphURL, !cachedURL.isEmpty,
           let cachedPath = video.telegraphPath, !cachedPath.isEmpty {
            _ = try await client.editPage(
                accessToken: token,
                path: cachedPath,
                title: title,
                content: content,
                authorName: channel,
                authorURL: videoURL
            )
            try await videoStore.setTelegraphPage(
                videoID: videoID, url: cachedURL, path: cachedPath, summaryHash: summaryHash
            )
            return TelegraphPublishResult(url: cachedURL, status: "updated")
        }

        let result = try await client.createPage(
            accessToken: token,
            title: title,
            content: content,
            authorName: channel,
            authorURL: videoURL
        )
        guard let url = result["url"] as? String, !url.isEmpty else {
            throw TelegraphError.missingPageURL
        }
        let path = (result["path"] as? String) ?? ""
        try await videoStore.setTelegraphPage(videoID: videoID, url: url, path: path, summaryHash: summaryHash)
        return TelegraphPublishResult(url: url, status: "published")
    }
}
