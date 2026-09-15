import AppKit
import Combine
import Foundation
import TubeFoldKit

/// A channel URL pasted into the Library add bar. Wrapped so the sheet can be
/// driven by `.sheet(item:)` — every paste is a fresh request.
struct ChannelExportRequest: Identifiable {
    let id = UUID()
    let reference: YouTubeChannelReference
}

/// Drives the channel-export sheet: options → running (listing, then per-video
/// progress) → finished / failed. The export itself is `TubeFoldKit`'s
/// `ChannelTranscriptExporter`; no provider runs and nothing enters the library.
@MainActor
final class ChannelExportViewModel: ObservableObject {
    enum Phase: Equatable {
        case configuring
        case listing
        case exporting(done: Int, total: Int, current: String)
        case finished(ChannelExportResult)
        case failed(String)
    }

    struct ChannelExportResult: Equatable {
        let folder: URL
        let channelTitle: String
        let saved: Int
        let skipped: Int
        let noCaptions: Int
        let failed: Int
        let cancelled: Bool
    }

    let reference: YouTubeChannelReference

    @Published private(set) var phase: Phase = .configuring
    @Published var includeVideos = true
    @Published var includeShorts = false
    @Published var includeStreams = false
    @Published var limitToNewest = false
    @Published var newestCount = 50
    @Published var skipExisting = true
    @Published var destination: URL

    private var exportTask: Task<Void, Never>?

    init(reference: YouTubeChannelReference) {
        self.reference = reference
        destination = AppSettings.shared.channelExportDirectory
        // A tab in the pasted URL (…/shorts) is the strongest hint of what the
        // user wants; without one, the Videos tab is the sensible default.
        if let tab = reference.tab {
            includeVideos = tab == .videos
            includeShorts = tab == .shorts
            includeStreams = tab == .streams
        }
    }

    var selectedTabs: [ChannelTab] {
        var tabs: [ChannelTab] = []
        if includeVideos {
            tabs.append(.videos)
        }
        if includeShorts {
            tabs.append(.shorts)
        }
        if includeStreams {
            tabs.append(.streams)
        }
        return tabs
    }

    var canStart: Bool {
        phase == .configuring && !selectedTabs.isEmpty && (!limitToNewest || newestCount > 0)
    }

    var isRunning: Bool {
        switch phase {
        case .listing, .exporting: true
        default: false
        }
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = destination
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose where the channel's transcript folder is created.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        destination = url
        AppSettings.shared.channelExportDirectory = url
    }

    func start() {
        guard canStart else { return }
        phase = .listing
        let options = ChannelExportOptions(
            outputDirectory: destination,
            tabs: selectedTabs,
            limit: limitToNewest ? newestCount : nil,
            skipExisting: skipExisting,
        )
        let reference = reference
        exportTask = Task { [weak self] in
            do {
                let summary = try await ChannelTranscriptExporter().export(
                    reference: reference,
                    options: options,
                    onListing: { listing in
                        Task { @MainActor in
                            self?.advance(to: .exporting(done: 0, total: listing.videos.count, current: ""))
                        }
                    },
                    onProgress: { progress in
                        Task { @MainActor in
                            self?.advance(to: .exporting(
                                done: progress.index,
                                total: progress.total,
                                current: progress.item.title,
                            ))
                        }
                    },
                )
                self?.phase = .finished(ChannelExportResult(
                    folder: summary.folder,
                    channelTitle: summary.channelTitle,
                    saved: summary.saved,
                    skipped: summary.skipped,
                    noCaptions: summary.noCaptions,
                    failed: summary.failed,
                    cancelled: summary.cancelled,
                ))
            } catch is CancellationError {
                // Cancelled while still listing — nothing was written.
                self?.phase = .configuring
            } catch let error as ChannelBrowseError {
                self?.phase = .failed(error.userMessage)
            } catch {
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Progress callbacks hop onto the main actor asynchronously, so one can
    /// land after the run has already finished — ignore it then.
    private func advance(to next: Phase) {
        guard isRunning else { return }
        phase = next
    }

    func cancel() {
        exportTask?.cancel()
    }

    func revealFolder() {
        guard case let .finished(result) = phase else { return }
        NSWorkspace.shared.activateFileViewerSelecting([result.folder])
    }

    func retry() {
        phase = .configuring
    }
}
