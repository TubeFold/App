import AppKit
import Combine
import Foundation

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published private(set) var videos: [LibraryVideo] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastLoadedAt: Date?
    @Published private(set) var publishingVideoIDs: Set<String> = []
    @Published private(set) var pdfRenderingVideoIDs: Set<String> = []
    @Published var urlInput = ""
    @Published private(set) var isSubmitting = false
    @Published private(set) var noticeMessage: String?
    @Published private(set) var suggestion: WatchSuggestion?
    /// Defaults to `true` so the empty-state / tip nudges stay hidden until the
    /// first status check resolves (no flash for users who already have it).
    @Published private(set) var extensionConnected = true

    private let service = LibraryService()
    private var refreshTask: Task<Void, Never>?
    private var isRefreshing = false
    private var noticeTask: Task<Void, Never>?

    var readyCount: Int {
        videos.filter(\.isReady).count
    }

    var activeCount: Int {
        videos
            .count(where: {
                ["queued", "fetchingMetadata", "fetchingTranscript", "generatingSummary"].contains($0.status)
            })
    }

    func startAutoRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await load(showSpinner: videos.isEmpty)

            while !Task.isCancelled {
                let delaySeconds = activeCount > 0 ? 2.0 : 6.0
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                if Task.isCancelled { return }
                await load(showSpinner: false)
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func load(showSpinner: Bool = true) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        if showSpinner {
            isLoading = true
        }
        defer {
            isRefreshing = false
            if showSpinner {
                isLoading = false
            }
        }

        do {
            let loadedVideos = try await service.listVideos()
            if loadedVideos != videos {
                videos = loadedVideos
            }
            lastLoadedAt = Date()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }

        await loadSuggestion()
        await loadExtensionStatus()
    }

    /// Best-effort: an old/missing backend just leaves the prior value, so the
    /// nudges never appear spuriously.
    private func loadExtensionStatus() async {
        guard let status = try? await service.extensionStatus() else { return }
        if status.connected != extensionConnected {
            extensionConnected = status.connected
        }
    }

    /// The subtle "get the extension" line under the add bar. Shown only once the
    /// library has content (the empty state carries its own bigger pitch), when the
    /// extension isn't connected, and only until the user dismisses it for good.
    var showExtensionTip: Bool {
        !videos.isEmpty && !extensionConnected && !AppSettings.shared.dismissedExtensionTip
    }

    func dismissExtensionTip() {
        AppSettings.shared.dismissedExtensionTip = true
        objectWillChange.send()
    }

    private func loadSuggestion() async {
        guard AppSettings.shared.showWatchSuggestions else {
            suggestion = nil
            return
        }
        // Best-effort: a missing/old backend simply means no suggestion. Never let it
        // clobber the main library error state.
        do {
            let loaded = try await service.latestWatchSuggestion()
            if loaded != suggestion {
                suggestion = loaded
            }
        } catch {
            // Ignore — suggestion is a non-critical enhancement.
        }
    }

    func acceptSuggestion() {
        guard let suggestion else { return }
        urlInput = suggestion.canonicalURL
        submitURL()
        dismissSuggestion()
    }

    func openSuggestion() {
        guard let suggestion else { return }
        if let local = videos.first(where: { $0.youtubeVideoID == suggestion.youtubeVideoID }), local.hasMarkdown {
            openMarkdown(local)
        } else if let url = suggestion.youtubeURL {
            NSWorkspace.shared.open(url)
        }
        dismissSuggestion()
    }

    func dismissSuggestion() {
        guard let dismissed = suggestion else { return }
        suggestion = nil
        Task {
            try? await service.dismissWatchSuggestion(youtubeID: dismissed.youtubeVideoID)
        }
    }

    var canSubmitURL: Bool {
        !isSubmitting && !urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func submitURL() {
        let trimmed = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSubmitting else { return }
        guard Self.looksLikeYouTubeURL(trimmed) else {
            errorMessage = "That doesn't look like a YouTube link."
            return
        }

        isSubmitting = true
        errorMessage = nil
        noticeMessage = nil
        Task {
            do {
                let response = try await service.createSummary(url: trimmed)
                urlInput = ""
                showNotice(Self.noticeText(for: response.status))
                await load(showSpinner: false)
            } catch {
                errorMessage = error.localizedDescription
            }
            isSubmitting = false
        }
    }

    func pasteFromClipboard() {
        let clip = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !clip.isEmpty else {
            errorMessage = "Clipboard is empty."
            return
        }
        urlInput = clip
        submitURL()
    }

    private func showNotice(_ message: String) {
        noticeMessage = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if Task.isCancelled { return }
            self?.noticeMessage = nil
        }
    }

    private static func noticeText(for status: String) -> String {
        switch status {
        case "already_exists":
            "This video is already in your Library."
        case "already_processing":
            "This video is already being processed."
        default:
            "Added — processing started."
        }
    }

    private static func looksLikeYouTubeURL(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.contains("youtube.com/") || lower.contains("youtu.be/")
    }

    func openYouTube(_ video: LibraryVideo) {
        guard let url = video.youtubeURL else { return }
        NSWorkspace.shared.open(url)
    }

    func openMarkdown(_ video: LibraryVideo) {
        guard let url = video.markdownURL else { return }
        NSWorkspace.shared.open(url)
    }

    func revealMarkdown(_ video: LibraryVideo) {
        guard let url = video.markdownURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Open the latest job's log folder in Finder, so the user can inspect why a
    /// summary failed (job.log + provider stdout/stderr live there). `open` drops
    /// the user *inside* the folder rather than selecting it in its parent.
    func revealLogs(_ video: LibraryVideo) {
        guard let url = video.jobLogURL else { return }
        NSWorkspace.shared.open(url)
    }

    func isRenderingPDF(_ video: LibraryVideo) -> Bool {
        pdfRenderingVideoIDs.contains(video.id)
    }

    /// Render the summary to PDF and open it in the default viewer (Preview),
    /// mirroring how "Open Telegraph" opens the article in the browser. The PDF is
    /// written next to the Markdown summary, so "Show Files" exposes every video artifact.
    ///
    /// Rendering is skipped when an up-to-date PDF already exists next to the summary:
    /// if the file is present and no older than the source Markdown, we just reopen it.
    /// (A regenerated summary rewrites the `.md`, making it newer, so the PDF is rebuilt.)
    func openPDF(_ video: LibraryVideo) {
        guard !pdfRenderingVideoIDs.contains(video.id),
              let sourceURL = video.markdownURL,
              let markdown = try? String(contentsOf: sourceURL, encoding: .utf8) else { return }
        let fileURL = Self.renderedArtifactURL(for: video, sourceURL: sourceURL, fileExtension: "pdf")
        if Self.isArtifactUpToDate(fileURL, source: sourceURL) {
            NSWorkspace.shared.open(fileURL)
            return
        }
        pdfRenderingVideoIDs.insert(video.id)
        Task {
            defer { pdfRenderingVideoIDs.remove(video.id) }
            do {
                let data = try await SummaryPDFRenderer().makePDFData(markdown: markdown, title: video.displayTitle)
                try data.write(to: fileURL)
                NSWorkspace.shared.open(fileURL)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// True when `artifact` exists and is no older than `source` — i.e. it was
    /// rendered from the current summary and can be reopened without re-rendering.
    static func isArtifactUpToDate(_ artifact: URL, source: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard let artifactDate = try? artifact.resourceValues(forKeys: keys).contentModificationDate else {
            return false
        }
        guard let sourceDate = try? source.resourceValues(forKeys: keys).contentModificationDate else {
            // No source timestamp to compare against — trust the existing artifact.
            return true
        }
        return artifactDate >= sourceDate
    }

    static func renderedArtifactURL(for video: LibraryVideo, sourceURL: URL, fileExtension: String) -> URL {
        sourceURL
            .deletingLastPathComponent()
            .appendingPathComponent(suggestedFilename(for: video, fallback: sourceURL, fileExtension: fileExtension))
    }

    /// Filename for a rendered artifact: "[TubeFold] <video title>.<ext>",
    /// sanitized for the filesystem. Falls back to the source file's name (with
    /// the requested extension swapped in) when there's no title.
    static func suggestedFilename(for video: LibraryVideo, fallback: URL, fileExtension: String) -> String {
        let title = video.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return fallback.deletingPathExtension().lastPathComponent + ".\(fileExtension)"
        }
        let sanitized = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\n", with: " ")
        let base = "[TubeFold] \(sanitized)"
        // Keep well under the 255-byte filename limit, leaving room for the extension.
        return "\(String(base.prefix(200))).\(fileExtension)"
    }

    func isPublishing(_ video: LibraryVideo) -> Bool {
        publishingVideoIDs.contains(video.id)
    }

    func publishToTelegraph(_ video: LibraryVideo) {
        guard !publishingVideoIDs.contains(video.id) else { return }
        publishingVideoIDs.insert(video.id)
        Task {
            do {
                let response = try await service.publishTelegraph(videoID: video.id)
                if let url = URL(string: response.url) {
                    NSWorkspace.shared.open(url)
                }
                await load(showSpinner: false)
            } catch {
                errorMessage = error.localizedDescription
            }
            publishingVideoIDs.remove(video.id)
        }
    }

    func regenerate(_ video: LibraryVideo) {
        Task {
            do {
                try await service.regenerate(videoID: video.id)
                await load(showSpinner: false)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func deleteVideo(_ video: LibraryVideo) {
        // Optimistically drop the row so the deletion feels instant; the next refresh
        // reconciles with the backend (and restores it if the call failed).
        videos.removeAll { $0.id == video.id }
        Task {
            do {
                try await service.delete(videoID: video.id)
                await load(showSpinner: false)
            } catch {
                errorMessage = error.localizedDescription
                await load(showSpinner: false)
            }
        }
    }
}
