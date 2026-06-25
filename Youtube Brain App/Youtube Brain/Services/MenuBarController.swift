import AppKit
import Foundation

@MainActor
final class MenuBarController: NSObject {
    static let shared = MenuBarController()

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let service = LibraryService()
    private var timer: Timer?
    private var hasLoadedInitialSnapshot = false
    private var knownVideoIDs = Set<String>()
    private var lastReadyVideo: LibraryVideo?
    private var latestVideo: LibraryVideo?

    private override init() {}

    func start() {
        configureButton(systemName: "play.rectangle", tooltip: "YouTube Brain")
        rebuildMenu(statusTitle: "YouTube Brain is ready", activeCount: 0)
        refresh()
        timer = Timer.scheduledTimer(timeInterval: 6, target: self, selector: #selector(pollFromTimer), userInfo: nil, repeats: true)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func refresh() {
        Task {
            do {
                let videos = try await service.listVideos()
                apply(videos: videos)
            } catch {
                configureButton(systemName: "exclamationmark.triangle", tooltip: "YouTube Brain needs attention")
                rebuildMenu(statusTitle: "Could not load Library", activeCount: 0)
            }
        }
    }

    private func apply(videos: [LibraryVideo]) {
        let sortedVideos = videos.sorted { $0.updatedAt > $1.updatedAt }
        latestVideo = sortedVideos.first
        let activeVideos = videos.filter(\.isActive)
        let readyVideos = sortedVideos.filter(\.isReady)
        let currentIDs = Set(videos.map(\.id))
        let hasNewVideo = hasLoadedInitialSnapshot && !currentIDs.subtracting(knownVideoIDs).isEmpty
        knownVideoIDs = currentIDs
        hasLoadedInitialSnapshot = true

        if let newestReady = readyVideos.first {
            if lastReadyVideo?.id != newestReady.id {
                lastReadyVideo = newestReady
            }
        }

        if !activeVideos.isEmpty {
            configureButton(systemName: "arrow.triangle.2.circlepath", tooltip: "\(activeVideos.count) video processing")
            rebuildMenu(statusTitle: hasNewVideo ? "New video received" : "Processing \(activeVideos.count) video", activeCount: activeVideos.count)
        } else if let ready = lastReadyVideo {
            configureButton(systemName: "checkmark.circle.fill", tooltip: "Summary ready: \(ready.displayTitle)")
            rebuildMenu(statusTitle: "Summary ready", activeCount: 0)
        } else {
            configureButton(systemName: "play.rectangle", tooltip: "YouTube Brain is ready")
            rebuildMenu(statusTitle: videos.isEmpty ? "Waiting for videos" : "Library is up to date", activeCount: 0)
        }
    }

    private func configureButton(systemName: String, tooltip: String) {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: systemName, accessibilityDescription: tooltip)
        button.imagePosition = .imageOnly
        button.toolTip = tooltip
    }

    private func rebuildMenu(statusTitle: String, activeCount: Int) {
        let menu = NSMenu()

        let status = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        if activeCount > 0 {
            let processing = NSMenuItem(title: "\(activeCount) processing", action: nil, keyEquivalent: "")
            processing.isEnabled = false
            menu.addItem(processing)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open Library", action: #selector(openApp), keyEquivalent: ""))

        let openSummary = NSMenuItem(title: "Open Latest Summary", action: #selector(openLatestSummary), keyEquivalent: "")
        openSummary.isEnabled = lastReadyVideo?.markdownURL != nil
        menu.addItem(openSummary)

        let openYouTube = NSMenuItem(title: "Open Latest Video", action: #selector(openLatestVideo), keyEquivalent: "")
        openYouTube.isEnabled = latestVideo?.youtubeURL != nil
        menu.addItem(openYouTube)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Refresh", action: #selector(refreshFromMenu), keyEquivalent: ""))
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    @objc private func openApp() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }

    @objc private func openLatestSummary() {
        guard let url = lastReadyVideo?.markdownURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openLatestVideo() {
        guard let url = latestVideo?.youtubeURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func refreshFromMenu() {
        refresh()
    }

    @objc private func pollFromTimer() {
        refresh()
    }
}
