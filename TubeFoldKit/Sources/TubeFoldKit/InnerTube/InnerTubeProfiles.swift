import Foundation

/// One InnerTube client identity used for `youtubei/v1/player` requests.
///
/// All client name/version constants live in this file only — they rot as
/// YouTube retires old client versions, so bumping them must be a one-file
/// change. Values confirmed 2026-07 against youtube-transcript-api and
/// NewPipe (both track current InnerTube client versions).
public struct InnerTubeClientProfile: Sendable, Equatable {
    public let clientName: String
    public let clientVersion: String
    public let userAgent: String?
    /// Extra `context.client` fields some clients require (e.g. iOS `deviceModel`).
    public let extraClientFields: [String: String]

    public init(
        clientName: String,
        clientVersion: String,
        userAgent: String? = nil,
        extraClientFields: [String: String] = [:]
    ) {
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.userAgent = userAgent
        self.extraClientFields = extraClientFields
    }
}

public enum InnerTubeProfiles {
    public static let playerEndpoint = URL(string: "https://www.youtube.com/youtubei/v1/player")!

    public static let android = InnerTubeClientProfile(
        clientName: "ANDROID",
        clientVersion: "20.10.38",
        userAgent: "com.google.android.youtube/20.10.38 (Linux; U; Android 13) gzip"
    )

    public static let ios = InnerTubeClientProfile(
        clientName: "IOS",
        clientVersion: "20.10.4",
        userAgent: "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
        extraClientFields: ["deviceMake": "Apple", "deviceModel": "iPhone16,2"]
    )

    public static let tvhtml5 = InnerTubeClientProfile(
        clientName: "TVHTML5",
        clientVersion: "7.20250312.16.00",
        userAgent: "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version"
    )

    /// Web client: only used to enrich metadata (its player response carries
    /// `microformat.playerMicroformatRenderer.publishDate`, which the mobile
    /// clients omit). Never used for caption tracks.
    public static let web = InnerTubeClientProfile(
        clientName: "WEB",
        clientVersion: "2.20250312.04.00",
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) "
            + "Chrome/124.0.0.0 Safari/537.36"
    )

    /// Multi-client fallback order for the `exp=xpe` class of failures: a
    /// client that stops being served captions is skipped in favor of the
    /// next one (parity mitigation from the research doc).
    public static let fallbackOrder: [InnerTubeClientProfile] = [android, ios, tvhtml5]
}
