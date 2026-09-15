import Foundation

// Channel listing over InnerTube's `youtubei/v1/browse`: resolve a handle to a
// `UC…` browse id, read a channel tab, then follow continuation tokens until
// the tab is exhausted.
//
// The renderer shapes YouTube returns here churn constantly (`videoRenderer` →
// `richItemRenderer`/`lockupViewModel` → whatever is next), so the payload is
// walked generically (`ChannelBrowseParser`) instead of being decoded into a
// mirror of the current wire format: every known video-carrying node shape is
// recognized, unknown ones are simply skipped.

/// One video in a channel listing (ids and titles only — dates and captions
/// come from the per-video player call).
public struct ChannelVideoEntry: Sendable, Equatable {
    public let videoID: String
    public let title: String

    public init(videoID: String, title: String) {
        self.videoID = videoID
        self.title = title
    }
}

/// A channel plus the videos read from its tabs, newest first.
public struct ChannelListing: Sendable, Equatable {
    public let channelID: String
    public let title: String
    public let url: String
    public let videos: [ChannelVideoEntry]

    public init(channelID: String, title: String, url: String, videos: [ChannelVideoEntry]) {
        self.channelID = channelID
        self.title = title
        self.url = url
        self.videos = videos
    }
}

public enum ChannelBrowseError: Error, Equatable {
    case unresolvedChannel(String)
    case emptyChannel(String)

    public var userMessage: String {
        switch self {
        case let .unresolvedChannel(label): "Could not resolve YouTube channel '\(label)'"
        case let .emptyChannel(label): "No videos found on '\(label)'"
        }
    }
}

extension InnerTubeClient {
    static let browseEndpoint = URL(string: "https://www.youtube.com/youtubei/v1/browse")!
    static let resolveURLEndpoint = URL(string: "https://www.youtube.com/youtubei/v1/navigation/resolve_url")!

    /// Hard stop on continuation paging so a pathological response can't loop
    /// forever; 400 pages is ~12k videos.
    static let maxChannelPages = 400

    /// Canonical `UC…` browse id for a channel reference.
    public func resolveChannelID(_ reference: YouTubeChannelReference) async throws -> String {
        switch reference.target {
        case let .browseID(id):
            return id
        case let .vanityURL(url):
            let json = try await innerTubeJSON(endpoint: Self.resolveURLEndpoint, body: ["url": url])
            guard let id = ChannelBrowseParser.string(in: json, atPath: ["endpoint", "browseEndpoint", "browseId"]),
                  id.hasPrefix("UC")
            else {
                throw ChannelBrowseError.unresolvedChannel(reference.label)
            }
            return id
        }
    }

    /// Every video of the requested tabs, newest first and de-duplicated.
    ///
    /// `limit` caps the number of videos collected. `onPage` reports the
    /// running total after each fetched page so callers can show progress.
    public func fetchChannelListing(
        reference: YouTubeChannelReference,
        tabs: [ChannelTab] = [.videos],
        limit: Int? = nil,
        onPage: (@Sendable (Int) -> Void)? = nil
    ) async throws -> ChannelListing {
        let channelID = try await resolveChannelID(reference)
        var title = ""
        var seen: Set<String> = []
        var videos: [ChannelVideoEntry] = []

        for tab in tabs {
            var page = try await innerTubeJSON(
                endpoint: Self.browseEndpoint,
                body: ["browseId": channelID, "params": tab.browseParams]
            )
            if title.isEmpty, let parsed = ChannelBrowseParser.channelTitle(in: page) {
                title = parsed
            }
            // YouTube answers a tab a channel does not have with its Home tab —
            // harvesting that would mix in unrelated recommendations.
            guard ChannelBrowseParser.selectedTabSlug(in: page) == tab.pathSlug else { continue }

            var pageIndex = 0
            while true {
                let parsed = ChannelBrowseParser.page(in: page)
                for entry in parsed.entries where seen.insert(entry.videoID).inserted {
                    videos.append(entry)
                    if let limit, videos.count >= limit {
                        onPage?(videos.count)
                        return listing(channelID: channelID, title: title, reference: reference, videos: videos)
                    }
                }
                onPage?(videos.count)

                pageIndex += 1
                guard pageIndex < Self.maxChannelPages, let token = parsed.continuation else { break }
                page = try await innerTubeJSON(endpoint: Self.browseEndpoint, body: ["continuation": token])
            }
        }

        guard !videos.isEmpty else {
            throw ChannelBrowseError.emptyChannel(reference.label)
        }
        return listing(channelID: channelID, title: title, reference: reference, videos: videos)
    }

    private func listing(
        channelID: String,
        title: String,
        reference: YouTubeChannelReference,
        videos: [ChannelVideoEntry]
    ) -> ChannelListing {
        ChannelListing(
            channelID: channelID,
            title: title.isEmpty ? reference.label : title,
            url: "https://www.youtube.com/channel/\(channelID)",
            videos: videos
        )
    }

    /// One InnerTube POST with the WEB client identity, decoded as loose JSON.
    func innerTubeJSON(endpoint: URL, body: [String: Any]) async throws -> Any {
        let profile = InnerTubeProfiles.web
        var payload: [String: Any] = [
            "context": ["client": ["clientName": profile.clientName, "clientVersion": profile.clientVersion]],
        ]
        for (key, value) in body {
            payload[key] = value
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("en-US", forHTTPHeaderField: "Accept-Language")
        if let userAgent = profile.userAgent {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }

        let (data, http) = try await transport(request)
        guard (200 ..< 300).contains(http.statusCode) else {
            throw InnerTubeError.httpStatus(http.statusCode, client: profile.clientName)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            throw InnerTubeError.malformedResponse(client: profile.clientName)
        }
        return json
    }
}

/// Generic reader for `browse` payloads — see the note at the top of the file
/// for why this walks the JSON instead of decoding a fixed shape.
enum ChannelBrowseParser {
    private nonisolated(unsafe) static let videoIDPattern = /[A-Za-z0-9_-]{11}/

    // MARK: - Videos

    /// One page's videos (in document order — YouTube serves newest first)
    /// together with the token that loads the next page, if any.
    struct Page {
        var entries: [ChannelVideoEntry] = []
        var continuation: String?
    }

    static func page(in json: Any) -> Page {
        var page = Page()
        walk(json, into: &page)
        return page
    }

    private static func walk(_ node: Any, into page: inout Page) {
        if let array = node as? [Any] {
            let before = page.entries.count
            for element in array {
                walk(element, into: &page)
            }
            // The grid is the one array holding both the video items and the
            // trailing `continuationItemRenderer`; the page's other tokens
            // (sort chips, the description panel) load something else entirely.
            if page.entries.count > before,
               let token = array.compactMap({ ($0 as? [String: Any]).flatMap(continuationToken(inItem:)) }).last
            {
                page.continuation = token
            }
            return
        }
        guard let object = node as? [String: Any] else { return }

        if let entry = entry(from: object) {
            page.entries.append(entry)
            // Don't descend into a consumed item: its menus repeat the same id.
            return
        }
        // Sorted keys so the walk order (and with it the video order across
        // sibling subtrees) doesn't depend on dictionary hashing.
        for key in object.keys.sorted() {
            walk(object[key] as Any, into: &page)
        }
    }

    private static func continuationToken(inItem object: [String: Any]) -> String? {
        guard let renderer = object["continuationItemRenderer"] as? [String: Any],
              let token = string(
                  in: renderer,
                  atPath: ["continuationEndpoint", "continuationCommand", "token"]
              ), !token.isEmpty else { return nil }
        return token
    }

    /// Recognize one video node across the shapes YouTube has shipped.
    private static func entry(from object: [String: Any]) -> ChannelVideoEntry? {
        // Current shape: `lockupViewModel` with a content id + content type.
        if let contentType = object["contentType"] as? String,
           contentType.contains("VIDEO"),
           let id = validVideoID(object["contentId"])
        {
            let title = string(in: object, atPath: ["metadata", "lockupMetadataViewModel", "title", "content"])
            return ChannelVideoEntry(videoID: id, title: title ?? "")
        }
        // Shorts shape: the id only appears inside the tap command.
        if let shorts = object["shortsLockupViewModel"] as? [String: Any] {
            if let id = validVideoID(
                string(in: shorts, atPath: ["onTap", "innertubeCommand", "reelWatchEndpoint", "videoId"])
            ) {
                let title = string(in: shorts, atPath: ["overlayMetadata", "primaryText", "content"])
                return ChannelVideoEntry(videoID: id, title: title ?? "")
            }
        }
        // Legacy shapes still served by some clients.
        for key in ["videoRenderer", "gridVideoRenderer", "playlistVideoRenderer", "reelItemRenderer"] {
            guard let renderer = object[key] as? [String: Any],
                  let id = validVideoID(renderer["videoId"]) else { continue }
            let title = text(renderer["title"]) ?? text(renderer["headline"])
            return ChannelVideoEntry(videoID: id, title: title ?? "")
        }
        return nil
    }

    private static func validVideoID(_ value: Any?) -> String? {
        guard let id = value as? String, id.wholeMatch(of: videoIDPattern) != nil else { return nil }
        return id
    }

    /// `{"simpleText": …}` / `{"runs": [{"text": …}]}` / `{"content": …}`.
    private static func text(_ value: Any?) -> String? {
        guard let object = value as? [String: Any] else { return nil }
        if let simple = object["simpleText"] as? String {
            return simple
        }
        if let content = object["content"] as? String {
            return content
        }
        if let runs = object["runs"] as? [Any] {
            let joined = runs.compactMap { ($0 as? [String: Any])?["text"] as? String }.joined()
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    // MARK: - Tab and channel identity

    /// Trailing path segment of the tab the response actually selected
    /// (`/@handle/videos` → `videos`), or `nil` when it can't be determined.
    static func selectedTabSlug(in json: Any) -> String? {
        guard let root = json as? [String: Any],
              let contents = root["contents"] as? [String: Any],
              let results = contents["twoColumnBrowseResultsRenderer"] as? [String: Any],
              let tabs = results["tabs"] as? [Any] else { return nil }
        for tab in tabs {
            guard let renderer = (tab as? [String: Any])?["tabRenderer"] as? [String: Any],
                  renderer["selected"] as? Bool == true else { continue }
            guard let url = string(
                in: renderer,
                atPath: ["endpoint", "commandMetadata", "webCommandMetadata", "url"]
            ) else { return nil }
            return url.split(separator: "/").last.map(String.init)
        }
        return nil
    }

    static func channelTitle(in json: Any) -> String? {
        guard let root = json as? [String: Any],
              let title = string(in: root, atPath: ["metadata", "channelMetadataRenderer", "title"]),
              !title.isEmpty else { return nil }
        return title
    }

    // MARK: - Path access

    /// String at a literal key path, e.g. `["endpoint", "browseEndpoint", "browseId"]`.
    static func string(in json: Any, atPath path: [String]) -> String? {
        var node: Any? = json
        for key in path {
            node = (node as? [String: Any])?[key]
        }
        return node as? String
    }
}
