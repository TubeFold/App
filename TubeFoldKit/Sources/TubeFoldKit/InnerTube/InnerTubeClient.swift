import Foundation

/// Native replacement for `youtube-transcript-api` + `yt-dlp`: one
/// `POST youtubei/v1/player` for metadata + caption-track listing, one
/// timedtext `GET` (`fmt=json3`) for the transcript text.
///
/// Client identities are tried in `InnerTubeProfiles.fallbackOrder` — a
/// profile that returns an unplayable/blocked response, or one that is served
/// no caption tracks while another client still gets them (`exp=xpe`), is
/// skipped in favor of the next.
public struct InnerTubeClient: Sendable {
    /// Injectable transport so tests never hit the network.
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let transport: Transport
    private let profiles: [InnerTubeClientProfile]

    public init(
        profiles: [InnerTubeClientProfile] = InnerTubeProfiles.fallbackOrder,
        transport: Transport? = nil
    ) {
        self.profiles = profiles
        self.transport = transport ?? Self.urlSessionTransport
    }

    @Sendable private static func urlSessionTransport(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }

    // MARK: - Player

    /// Metadata + caption tracks for a video, via the first cooperating client.
    public func fetchVideoInfo(videoID: String) async throws -> (metadata: VideoMetadata, tracks: [CaptionTrack]) {
        guard videoID.wholeMatch(of: /[A-Za-z0-9_-]{11}/) != nil else {
            throw InnerTubeError.invalidVideoID(videoID)
        }

        var playableWithoutCaptions: PlayerResponse?
        var firstError: Error?

        for profile in profiles {
            let response: PlayerResponse
            do {
                response = try await playerResponse(videoID: videoID, profile: profile)
            } catch {
                if firstError == nil { firstError = error }
                continue
            }

            let status = response.playabilityStatus?.status ?? "OK"
            guard status == "OK" else {
                if firstError == nil {
                    firstError = InnerTubeError.unplayable(status: status, reason: response.playabilityStatus?.reason)
                }
                continue
            }

            let tracks = response.captionTracks
            if !tracks.isEmpty {
                return (await enrichPublishDate(response.metadata(videoID: videoID)), tracks)
            }
            // Playable but captionless for this client — remember it for
            // metadata and keep probing the other clients for tracks.
            if playableWithoutCaptions == nil {
                playableWithoutCaptions = response
            }
        }

        if let response = playableWithoutCaptions {
            return (await enrichPublishDate(response.metadata(videoID: videoID)), [])
        }
        throw firstError ?? InnerTubeError.noTranscript
    }

    /// The mobile clients omit `microformat` (and with it the publish date the
    /// Telegraph header shows), so fill it from a WEB-client player call.
    /// Best-effort: any failure just leaves `publishedAt` empty — metadata is
    /// never fatal.
    private func enrichPublishDate(_ metadata: VideoMetadata) async -> VideoMetadata {
        guard metadata.publishedAt.isEmpty else { return metadata }
        guard let response = try? await playerResponse(videoID: metadata.videoID, profile: InnerTubeProfiles.web),
              let renderer = response.microformat?.playerMicroformatRenderer else {
            return metadata
        }
        let publishedAt = PlayerResponse.dateOnly(renderer.publishDate ?? renderer.uploadDate ?? "")
        guard !publishedAt.isEmpty else { return metadata }
        return VideoMetadata(
            videoID: metadata.videoID,
            title: metadata.title,
            channel: metadata.channel,
            durationSeconds: metadata.durationSeconds,
            publishedAt: publishedAt,
            url: metadata.url
        )
    }

    func playerResponse(videoID: String, profile: InnerTubeClientProfile) async throws -> PlayerResponse {
        var client: [String: String] = [
            "clientName": profile.clientName,
            "clientVersion": profile.clientVersion,
        ]
        for (key, value) in profile.extraClientFields {
            client[key] = value
        }
        let body: [String: Any] = ["context": ["client": client], "videoId": videoID]

        var request = URLRequest(url: InnerTubeProfiles.playerEndpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("en-US", forHTTPHeaderField: "Accept-Language")
        if let userAgent = profile.userAgent {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }

        let (data, http) = try await transport(request)
        guard (200 ..< 300).contains(http.statusCode) else {
            throw InnerTubeError.httpStatus(http.statusCode, client: profile.clientName)
        }
        do {
            return try JSONDecoder().decode(PlayerResponse.self, from: data)
        } catch {
            throw InnerTubeError.malformedResponse(client: profile.clientName)
        }
    }

    // MARK: - Transcript

    /// Full transcript flow: list tracks → select the original-language track
    /// → download and join it. A failed transcript is fatal (unlike metadata).
    public func fetchTranscript(videoID: String, allowAny: Bool = true) async throws -> TranscriptResult {
        let (_, tracks) = try await fetchVideoInfo(videoID: videoID)
        guard !tracks.isEmpty else {
            throw InnerTubeError.transcriptsDisabled
        }
        let track = try TranscriptSelection.selectTrack(tracks, allowAny: allowAny)
        let text = try await downloadTranscriptText(track: track)
        guard text.count >= 20 else {
            throw InnerTubeError.emptyTranscript
        }
        return TranscriptResult(
            text: text,
            language: track.languageName,
            languageCode: track.languageCode,
            isGenerated: track.isGenerated
        )
    }

    public func downloadTranscriptText(track: CaptionTrack) async throws -> String {
        guard let url = URL(string: track.baseURL) else {
            throw InnerTubeError.noTranscript
        }
        var request = URLRequest(url: url)
        request.setValue("en-US", forHTTPHeaderField: "Accept-Language")

        let (data, http) = try await transport(request)
        guard (200 ..< 300).contains(http.statusCode) else {
            throw InnerTubeError.httpStatus(http.statusCode, client: "timedtext")
        }
        return try Self.timedTextToText(data)
    }

    /// Parse a timedtext payload into one whitespace-normalized line.
    ///
    /// The signed `baseUrl` ignores a `fmt` override, so we take what YouTube
    /// serves: timedtext XML (`<text>`/`<p>` elements, srv1/srv3) today, with
    /// the `json3` shape also accepted in case a client variant returns it.
    static func timedTextToText(_ data: Data) throws -> String {
        let head = String(decoding: data.prefix(64), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if head.hasPrefix("{") {
            return try json3ToText(data)
        }
        let snippets = TimedTextXMLCollector.snippets(from: data)
        guard !snippets.isEmpty else {
            throw InnerTubeError.noTranscript
        }
        return TranscriptSelection.snippetsToText(snippets)
    }

    /// Parse a timedtext `fmt=json3` payload into one whitespace-normalized line.
    static func json3ToText(_ data: Data) throws -> String {
        struct Json3: Decodable {
            struct Event: Decodable {
                struct Seg: Decodable {
                    let utf8: String?
                }

                let segs: [Seg]?
            }

            let events: [Event]?
        }

        guard let parsed = try? JSONDecoder().decode(Json3.self, from: data) else {
            throw InnerTubeError.noTranscript
        }
        let snippets = (parsed.events ?? []).map { event in
            (event.segs ?? []).compactMap(\.utf8).joined()
        }
        return TranscriptSelection.snippetsToText(snippets)
    }
}

/// Collects the text of `<text>` (srv1) / `<p>` (srv3) elements from a
/// timedtext XML document; nested `<s>` word segments contribute their
/// characters naturally, and `XMLParser` decodes entities like `&#39;`.
private final class TimedTextXMLCollector: NSObject, XMLParserDelegate {
    private var snippets: [String] = []
    private var current = ""
    private var depth = 0

    static func snippets(from data: Data) -> [String] {
        let collector = TimedTextXMLCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.parse()
        return collector.snippets
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        if elementName == "text" || elementName == "p" {
            depth += 1
            if depth == 1 {
                current = ""
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if depth > 0 {
            current += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        if elementName == "text" || elementName == "p" {
            depth -= 1
            if depth == 0 {
                snippets.append(current)
            }
        }
    }
}
