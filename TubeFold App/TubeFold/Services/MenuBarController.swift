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
    private var iconMode: IconMode?
    private var currentSymbol: String?
    /// Whether the Chrome extension is connected. Defaults to `true` so the
    /// "Get the Chrome Extension…" item stays hidden until we know otherwise.
    private var extensionConnected = true

    /// How long the "summary ready" checkmark lingers after a completion before the
    /// icon settles back to the calm app-icon default.
    private let readyDisplayDuration: TimeInterval = 8
    private var readyResetTimer: Timer?

    override private init() {}

    func start() {
        statusItem.button?.wantsLayer = true
        applyMenuBarVisibility()
        setIconMode(.idle, tooltip: "TubeFold")
        rebuildMenu(statusTitle: "TubeFold is ready")
        refresh()
        timer = Timer.scheduledTimer(
            timeInterval: 6,
            target: self,
            selector: #selector(pollFromTimer),
            userInfo: nil,
            repeats: true,
        )
    }

    /// Show or hide the status item per the user's preference. Polling keeps
    /// running while hidden so the app still auto-opens Telegraph if enabled.
    func applyMenuBarVisibility() {
        statusItem.isVisible = !AppSettings.shared.hideMenuBarIcon
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        cancelReadyReset()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func refresh() {
        Task {
            do {
                let videos = try await service.listVideos()
                if let status = try? await service.extensionStatus() {
                    extensionConnected = status.connected
                }
                apply(videos: videos)
            } catch {
                setIconMode(.error, tooltip: "TubeFold needs attention")
                rebuildMenu(statusTitle: "Could not load Library")
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
            cancelReadyReset()
            setIconMode(.processing, tooltip: "\(activeVideos.count) video processing")
            rebuildMenu(statusTitle: hasNewVideo ? "New video received" : "Processing \(activeVideos.count) video")
        } else if let ready = lastReadyVideo, !newlyReady.isEmpty {
            // A summary just finished: pop the checkmark, then auto-settle back to the app icon.
            setIconMode(.ready, tooltip: "Summary ready: \(ready.displayTitle)")
            rebuildMenu(statusTitle: "Summary ready")
            scheduleReadyReset()
        } else if readyResetTimer == nil {
            // Calm default: the app icon. While the post-completion checkmark window is
            // still counting down, leave it alone and let the timer revert us.
            setIconMode(.idle, tooltip: videos.isEmpty ? "Waiting for videos" : "Library is up to date")
            rebuildMenu(statusTitle: videos.isEmpty ? "Waiting for videos" : "Library is up to date")
        }

        // On completion, open the Telegraph page directly — no notification.
        if AppSettings.shared.autoOpenTelegraph {
            for completed in newlyReady {
                openTelegraph(for: completed)
            }
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
            // Swap to a circular-arrows glyph so the spin reads as "working", not a spinning play button.
            setButtonImage("arrow.triangle.2.circlepath", tooltip: tooltip)
            startSpinning()
        case .ready:
            // Coming out of processing: let the spinner coast to a stop, then swap to the
            // checkmark with a spring pop. Otherwise (e.g. app launch) just settle in quietly.
            if previousMode == .processing {
                decelerateSpinning { [weak self] in
                    self?.setButtonImage("checkmark.circle.fill", tooltip: tooltip)
                    self?.popIn()
                }
            } else {
                stopSpinning()
                setButtonImage("checkmark.circle.fill", tooltip: tooltip)
                popIn()
            }
        case .error:
            stopSpinning()
            setButtonImage("exclamationmark.triangle", tooltip: tooltip)
        case .idle:
            stopSpinning()
            setAppIconImage(tooltip: tooltip)
        }
    }

    /// Cached menu-bar brand glyph, built on first successful load.
    private var cachedAppIcon: NSImage?

    /// The TubeFold mark for the menu bar — the play-triangle-with-folded-corner from the
    /// app icon, on a transparent background (`MenuBarMark` bundled asset). We ship a
    /// dedicated transparent picture rather than the full AppIcon because the AppIcon
    /// carries its own dark rounded-square background, which renders as an unreadable dark
    /// blob in the bar. Kept as a colored (non-template) image so the red fold survives.
    private func appIconImage() -> NSImage? {
        if let cachedAppIcon { return cachedAppIcon }
        guard let icon = NSImage(named: "MenuBarMark") else { return nil }
        icon.isTemplate = false
        cachedAppIcon = icon
        return icon
    }

    private func setAppIconImage(tooltip: String) {
        guard let button = statusItem.button else { return }
        guard let image = appIconImage() else {
            setButtonImage("play.rectangle", tooltip: tooltip)
            return
        }
        let key = "TubeFold.icon"
        if let current = currentSymbol, current != key {
            crossfadeImage()
        }
        currentSymbol = key
        button.image = image
        button.imagePosition = .imageOnly
    }

    // MARK: - Ready-state auto-reset

    /// Hold the checkmark for `readyDisplayDuration`, then fall back to the app icon.
    private func scheduleReadyReset() {
        readyResetTimer?.invalidate()
        readyResetTimer = Timer.scheduledTimer(
            timeInterval: readyDisplayDuration,
            target: self,
            selector: #selector(readyResetFired),
            userInfo: nil,
            repeats: false,
        )
    }

    private func cancelReadyReset() {
        readyResetTimer?.invalidate()
        readyResetTimer = nil
    }

    @objc private func readyResetFired() {
        readyResetTimer = nil
        guard iconMode == .ready else { return }
        let title = knownVideoIDs.isEmpty ? "Waiting for videos" : "Library is up to date"
        setIconMode(.idle, tooltip: title)
        rebuildMenu(statusTitle: title)
    }

    private func setButtonImage(_ systemName: String, tooltip: String) {
        guard let button = statusItem.button else { return }
        // Cross-fade whenever the glyph actually changes; skip on first paint / no-op swaps.
        if let current = currentSymbol, current != systemName {
            crossfadeImage()
        }
        currentSymbol = systemName
        button.image = NSImage(systemSymbolName: systemName, accessibilityDescription: tooltip)
        button.imagePosition = .imageOnly
    }

    // MARK: - Animation primitives

    /// Pin the layer's anchor to its geometric center (compensating position so it doesn't
    /// visually jump) so rotation and scale always pivot around the glyph, even after the
    /// variable-length button resizes on an icon swap.
    private func centerAnchorPoint() {
        guard let layer = statusItem.button?.layer else { return }
        let center = CGPoint(x: 0.5, y: 0.5)
        guard layer.anchorPoint != center else { return }
        let bounds = layer.bounds
        let new = CGPoint(x: bounds.width * center.x, y: bounds.height * center.y)
            .applying(layer.affineTransform())
        let old = CGPoint(x: bounds.width * layer.anchorPoint.x, y: bounds.height * layer.anchorPoint.y)
            .applying(layer.affineTransform())
        layer.position = CGPoint(
            x: layer.position.x - old.x + new.x,
            y: layer.position.y - old.y + new.y,
        )
        layer.anchorPoint = center
    }

    private func crossfadeImage(duration: CFTimeInterval = 0.2) {
        guard let layer = statusItem.button?.layer else { return }
        let fade = CATransition()
        fade.type = .fade
        fade.duration = duration
        layer.add(fade, forKey: "fade")
    }

    private func startSpinning() {
        centerAnchorPoint()
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

    /// Ease the spinner from its current angle to rest along the shortest arc, then run `completion`.
    private func decelerateSpinning(then completion: @escaping () -> Void) {
        guard let layer = statusItem.button?.layer else {
            completion()
            return
        }
        let current = (layer.presentation()?.value(forKeyPath: "transform.rotation.z") as? CGFloat) ?? 0
        layer.removeAnimation(forKey: "spin")
        guard current != 0 else {
            completion()
            return
        }

        let settle = CABasicAnimation(keyPath: "transform.rotation.z")
        settle.fromValue = current
        settle.toValue = 0
        settle.duration = 0.3
        settle.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        layer.add(settle, forKey: "settle")
        CATransaction.commit()
    }

    /// Spring the glyph up from a slightly shrunken state — the "summary is ready" celebration.
    private func popIn() {
        centerAnchorPoint()
        guard let layer = statusItem.button?.layer else { return }
        let pop = CASpringAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.6
        pop.toValue = 1.0
        pop.mass = 0.6
        pop.stiffness = 180
        pop.damping = 9
        pop.initialVelocity = 6
        pop.duration = pop.settlingDuration
        layer.add(pop, forKey: "pop")
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

    private func rebuildMenu(statusTitle: String) {
        let menu = NSMenu()

        let status = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open Library", action: #selector(openApp), keyEquivalent: ""))

        let openSummary = NSMenuItem(
            title: "Open Latest Summary",
            action: #selector(openLatestSummary),
            keyEquivalent: "",
        )
        openSummary.isEnabled = lastReadyVideo?.markdownURL != nil
        menu.addItem(openSummary)

        let openYouTube = NSMenuItem(title: "Open Latest Video", action: #selector(openLatestVideo), keyEquivalent: "")
        openYouTube.isEnabled = latestVideo?.youtubeURL != nil
        menu.addItem(openYouTube)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Refresh", action: #selector(refreshFromMenu), keyEquivalent: ""))

        let checkForUpdates = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdatesFromMenu),
            keyEquivalent: "",
        )
        checkForUpdates.isEnabled = UpdaterController.shared.canCheckForUpdates
        menu.addItem(checkForUpdates)

        // Only surface the install link to people who don't already have the extension.
        if !extensionConnected {
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(
                title: "Get the Chrome Extension…",
                action: #selector(openChromeStore),
                keyEquivalent: "",
            ))
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit TubeFold", action: #selector(quitApp), keyEquivalent: "q"))

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

    @objc private func checkForUpdatesFromMenu() {
        UpdaterController.shared.checkForUpdates()
    }

    @objc private func openChromeStore() {
        NSWorkspace.shared.open(TubeFoldLinks.chromeWebStore)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    @objc private func pollFromTimer() {
        refresh()
    }
}
