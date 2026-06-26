import AppKit
import Foundation

@MainActor
final class MenuBarController: NSObject {
    static let shared = MenuBarController()

    private enum IconMode: Equatable {
        case idle
        case processing
        case ready
        case error
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let service = LibraryService()
    private var timer: Timer?
    private var hasLoadedInitialSnapshot = false
    private var knownVideoIDs = Set<String>()
    private var knownReadyIDs = Set<String>()
    private var lastReadyVideo: LibraryVideo?
    private var latestVideo: LibraryVideo?
    private var iconMode: IconMode = .idle

    private override init() {}

    func start() {
        statusItem.button?.wantsLayer = true
        setIconMode(.idle, tooltip: "TubeFold")
        rebuildMenu(statusTitle: "TubeFold is ready", activeCount: 0)
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
                setIconMode(.error, tooltip: "TubeFold needs attention")
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
        let currentReadyIDs = Set(readyVideos.map(\.id))
        let hasNewVideo = hasLoadedInitialSnapshot && !currentIDs.subtracting(knownVideoIDs).isEmpty

        // Summaries that just transitioned into the ready state since the last poll.
        let newlyReady: [LibraryVideo] = hasLoadedInitialSnapshot
            ? readyVideos.filter { !knownReadyIDs.contains($0.id) }
            : []

        knownVideoIDs = currentIDs
        knownReadyIDs = currentReadyIDs
        hasLoadedInitialSnapshot = true
        lastReadyVideo = readyVideos.first

        if !activeVideos.isEmpty {
            setIconMode(.processing, tooltip: "\(activeVideos.count) video processing")
            rebuildMenu(statusTitle: hasNewVideo ? "New video received" : "Processing \(activeVideos.count) video", activeCount: activeVideos.count)
        } else if let ready = lastReadyVideo {
            setIconMode(.ready, tooltip: "Summary ready: \(ready.displayTitle)")
            rebuildMenu(statusTitle: "Summary ready", activeCount: 0)
        } else {
            setIconMode(.idle, tooltip: videos.isEmpty ? "Waiting for videos" : "Library is up to date")
            rebuildMenu(statusTitle: videos.isEmpty ? "Waiting for videos" : "Library is up to date", activeCount: 0)
        }

        // On completion, open the Telegraph page directly — no notification.
        for completed in newlyReady {
            openTelegraph(for: completed)
        }
    }

    // MARK: - Status icon

    private func setIconMode(_ mode: IconMode, tooltip: String) {
        statusItem.button?.toolTip = tooltip

        guard mode != iconMode else { return }
        let previousMode = iconMode
        iconMode = mode

        switch mode {
        case .processing:
            // Keep our own icon and spin the icon itself — no swap to a circular-arrows glyph.
            setButtonImage("play.rectangle", tooltip: tooltip)
            startSpinning()
        case .ready:
            stopSpinning()
            setButtonImage("checkmark.circle.fill", tooltip: tooltip)
            // Only celebrate a fresh transition into "ready", not the initial app launch.
            if previousMode == .processing {
                bounceIcon()
            }
        case .error:
            stopSpinning()
            setButtonImage("exclamationmark.triangle", tooltip: tooltip)
        case .idle:
            stopSpinning()
            setButtonImage("play.rectangle", tooltip: tooltip)
        }
    }

    private func setButtonImage(_ systemName: String, tooltip: String) {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: systemName, accessibilityDescription: tooltip)
        button.imagePosition = .imageOnly
    }

    private func startSpinning() {
        guard let layer = statusItem.button?.layer else { return }
        guard layer.animation(forKey: "spin") == nil else { return }

        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = -Double.pi * 2
        rotation.duration = 1.1
        rotation.repeatCount = .infinity
        rotation.isRemovedOnCompletion = false
        rotation.timingFunction = CAMediaTimingFunction(name: .linear)
        layer.add(rotation, forKey: "spin")
    }

    private func stopSpinning() {
        statusItem.button?.layer?.removeAnimation(forKey: "spin")
    }

    private func bounceIcon() {
        guard let layer = statusItem.button?.layer else { return }
        let bounce = CAKeyframeAnimation(keyPath: "transform.scale")
        bounce.values = [1.0, 1.35, 0.88, 1.12, 1.0]
        bounce.keyTimes = [0.0, 0.3, 0.55, 0.8, 1.0]
        bounce.duration = 0.55
        bounce.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(bounce, forKey: "bounce")
    }

    // MARK: - Completion

    /// When a summary becomes ready, publish it to Telegraph (if not already published)
    /// and open the page in the browser right away — no notification.
    private func openTelegraph(for video: LibraryVideo) {
        if let existing = video.telegraphURL, !existing.isEmpty, let url = URL(string: existing) {
            NSWorkspace.shared.open(url)
            return
        }
        Task {
            do {
                let response = try await service.publishTelegraph(videoID: video.id)
                if let url = URL(string: response.url) {
                    NSWorkspace.shared.open(url)
                }
            } catch {
                NSLog("tubefold: telegraph auto-publish failed: %@", error.localizedDescription)
            }
        }
    }

    // MARK: - Menu

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
