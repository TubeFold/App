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

    private let service = LibraryService()
    private var refreshTask: Task<Void, Never>?
    private var isRefreshing = false

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
