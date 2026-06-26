import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published private(set) var videos: [LibraryVideo] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastLoadedAt: Date?
    @Published private(set) var publishingVideoIDs: Set<String> = []
    @Published var urlInput = ""
    @Published private(set) var isSubmitting = false
    @Published private(set) var noticeMessage: String?

    private let service = LibraryService()
    private var refreshTask: Task<Void, Never>?
    private var isRefreshing = false
    private var noticeTask: Task<Void, Never>?

    var readyCount: Int {
        videos.filter(\.isReady).count
    }

    var activeCount: Int {
        videos.filter { ["queued", "fetchingMetadata", "fetchingTranscript", "generatingSummary"].contains($0.status) }.count
    }

    func startAutoRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.load(showSpinner: self.videos.isEmpty)

            while !Task.isCancelled {
                let delaySeconds = self.activeCount > 0 ? 2.0 : 6.0
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                if Task.isCancelled { return }
                await self.load(showSpinner: false)
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
            return "This video is already in your Library."
        case "already_processing":
            return "This video is already being processed."
        default:
            return "Added — processing started."
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

    func saveMarkdownCopy(_ video: LibraryVideo) {
        guard let sourceURL = video.markdownURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.markdown]
        panel.nameFieldStringValue = sourceURL.lastPathComponent
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let destinationURL = panel.url {
            do {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
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
}
