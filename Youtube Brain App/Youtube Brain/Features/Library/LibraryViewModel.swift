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

    var readyCount: Int {
        videos.filter(\.isReady).count
    }

    var activeCount: Int {
        videos.filter { ["queued", "fetchingMetadata", "fetchingTranscript", "generatingSummary"].contains($0.status) }.count
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            videos = try await service.listVideos()
            lastLoadedAt = Date()
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
                await load()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
