import Foundation

/// Bulk transcript export for a whole channel: list the channel's videos, then
/// download each transcript into one folder of dated `.md` files.
///
/// Deliberately *not* part of `SummaryPipeline` — no provider runs, nothing is
/// stored in the library, and a per-video failure never aborts the run: the
/// deliverable is the folder plus an `index.md` recording what happened.
public struct ChannelExportOptions: Sendable {
    /// Parent directory; the channel folder is created inside it.
    public var outputDirectory: URL
    public var tabs: [ChannelTab]
    /// Stop after this many videos (newest first) — `nil` for the whole channel.
    public var limit: Int?
    public var allowAnyTranscriptLanguage: Bool
    /// Leave videos already present in the folder untouched (resume support).
    public var skipExisting: Bool
    public var writeIndex: Bool
    /// Pause between per-video requests, to stay polite to YouTube.
    public var requestDelay: Duration

    public init(
        outputDirectory: URL,
        tabs: [ChannelTab] = [.videos],
        limit: Int? = nil,
        allowAnyTranscriptLanguage: Bool = true,
        skipExisting: Bool = true,
        writeIndex: Bool = true,
        requestDelay: Duration = .milliseconds(300)
    ) {
        self.outputDirectory = outputDirectory
        self.tabs = tabs
        self.limit = limit
        self.allowAnyTranscriptLanguage = allowAnyTranscriptLanguage
        self.skipExisting = skipExisting
        self.writeIndex = writeIndex
        self.requestDelay = requestDelay
    }
}

public enum ChannelExportOutcome: Sendable, Equatable {
    case saved(path: String)
    case skipped(reason: String)
    case failed(message: String)
}

/// One video's result in the export.
public struct ChannelExportItem: Sendable, Equatable {
    public let videoID: String
    public let title: String
    public let publishedAt: String
    public let outcome: ChannelExportOutcome

    public var url: String {
        "https://www.youtube.com/watch?v=\(videoID)"
    }
}

/// Progress for one video, reported as soon as it is resolved.
public struct ChannelExportProgress: Sendable {
    public let index: Int
    public let total: Int
    public let item: ChannelExportItem
}

public struct ChannelExportSummary: Sendable {
    public let folder: URL
    public let channelTitle: String
    public let items: [ChannelExportItem]

    public var saved: Int {
        items.filter {
            if case .saved = $0.outcome {
                true
            } else {
                false
            }
        }.count
    }

    public var skipped: Int {
        items.filter {
            if case .skipped = $0.outcome {
                true
            } else {
                false
            }
        }.count
    }

    public var failed: Int {
        items.filter {
            if case .failed = $0.outcome {
                true
            } else {
                false
            }
        }.count
    }
}

public struct ChannelTranscriptExporter: Sendable {
    private let client: InnerTubeClient

    public init(client: InnerTubeClient = InnerTubeClient()) {
        self.client = client
    }

    /// List the channel and write one transcript file per video.
    ///
    /// Throws only when the channel itself can't be listed; per-video failures
    /// are recorded as `.failed` items and the run continues.
    public func export(
        reference: YouTubeChannelReference,
        options: ChannelExportOptions,
        onListing: (@Sendable (ChannelListing) -> Void)? = nil,
        onProgress: (@Sendable (ChannelExportProgress) -> Void)? = nil
    ) async throws -> ChannelExportSummary {
        let tabs = options.tabs.isEmpty ? [reference.tab ?? .videos] : options.tabs
        let listing = try await client.fetchChannelListing(
            reference: reference,
            tabs: tabs,
            limit: options.limit
        )
        onListing?(listing)

        let folder = options.outputDirectory
            .appendingPathComponent(Filenames.safeFilename(listing.title))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let existing = options.skipExisting ? TranscriptDocument.existingVideoIDs(in: folder) : []

        var items: [ChannelExportItem] = []
        for (offset, video) in listing.videos.enumerated() {
            let item: ChannelExportItem
            if existing.contains(video.videoID) {
                item = ChannelExportItem(
                    videoID: video.videoID,
                    title: video.title,
                    publishedAt: "",
                    outcome: .skipped(reason: "already exported")
                )
            } else {
                if offset > 0 {
                    try? await Task.sleep(for: options.requestDelay)
                }
                item = await exportOne(video: video, folder: folder, options: options)
            }
            items.append(item)
            onProgress?(ChannelExportProgress(index: offset + 1, total: listing.videos.count, item: item))
        }

        if options.writeIndex {
            let index = Self.indexMarkdown(listing: listing, items: items)
            try? index.write(to: folder.appendingPathComponent("index.md"), atomically: true, encoding: .utf8)
        }
        return ChannelExportSummary(folder: folder, channelTitle: listing.title, items: items)
    }

    private func exportOne(
        video: ChannelVideoEntry,
        folder: URL,
        options: ChannelExportOptions
    ) async -> ChannelExportItem {
        var metadata = VideoMetadata.stub(
            videoID: video.videoID,
            url: "https://www.youtube.com/watch?v=\(video.videoID)"
        )
        do {
            let (fetched, tracks) = try await client.fetchVideoInfo(videoID: video.videoID)
            metadata = fetched
            let track = try TranscriptSelection.selectTrack(tracks, allowAny: options.allowAnyTranscriptLanguage)
            let text = try await client.downloadTranscriptText(track: track)
            guard text.count >= 20 else {
                throw InnerTubeError.emptyTranscript
            }
            let transcript = TranscriptResult(
                text: text,
                language: track.languageName,
                languageCode: track.languageCode,
                isGenerated: track.isGenerated
            )
            let stem = TranscriptDocument.filenameStem(publishedAt: metadata.publishedAt, title: metadata.title)
            let path = try Filenames.uniqueMarkdownPath(outputDir: folder, title: stem)
            try TranscriptDocument.markdown(metadata: metadata, transcript: transcript)
                .write(to: path, atomically: true, encoding: .utf8)
            return ChannelExportItem(
                videoID: metadata.videoID,
                title: metadata.title,
                publishedAt: metadata.publishedAt,
                outcome: .saved(path: path.path)
            )
        } catch {
            let message = (error as? InnerTubeError)?.userMessage
                ?? (error as? LocalizedError)?.errorDescription
                ?? "\(error)"
            return ChannelExportItem(
                videoID: video.videoID,
                title: metadata.title == video.videoID ? video.title : metadata.title,
                publishedAt: metadata.publishedAt,
                outcome: .failed(message: message)
            )
        }
    }

    /// Folder manifest: every listed video with its date, link and outcome,
    /// newest first (undated videos last).
    static func indexMarkdown(listing: ChannelListing, items: [ChannelExportItem]) -> String {
        let sorted = items.sorted { lhs, rhs in
            let left = lhs.publishedAt.isEmpty ? "0000-00-00" : lhs.publishedAt
            let right = rhs.publishedAt.isEmpty ? "0000-00-00" : rhs.publishedAt
            return left > right
        }
        var lines = [
            "# \(listing.title)",
            "",
            "[\(listing.url)](\(listing.url)) · \(items.count) videos · "
                + "exported \(SummaryText.processedAtNow())",
            "",
            "| Published | Title | Status |",
            "| --- | --- | --- |",
        ]
        for item in sorted {
            let status = switch item.outcome {
            case let .saved(path): "saved — `\(URL(fileURLWithPath: path).lastPathComponent)`"
            case let .skipped(reason): "skipped (\(reason))"
            case let .failed(message): "failed — \(message)"
            }
            let title = item.title.isEmpty ? item.videoID : item.title
            let escaped = title.replacingOccurrences(of: "|", with: "\\|")
            lines.append(
                "| \(item.publishedAt.isEmpty ? "—" : item.publishedAt) "
                    + "| [\(escaped)](\(item.url)) | \(status) |"
            )
        }
        return lines.joined(separator: "\n") + "\n" + SummaryText.footerMarkdown()
    }
}
