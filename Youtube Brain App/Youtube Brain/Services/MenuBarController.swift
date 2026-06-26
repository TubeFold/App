import AppKit
import Foundation
import UserNotifications

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
    private var notificationsReady = false

    private static let readyCategoryID = "summary.ready"
    private static let openSummaryActionID = "summary.open"
    private static let publishTelegraphActionID = "summary.telegraph"

    private override init() {}

    func start() {
        statusItem.button?.wantsLayer = true
        setIconMode(.idle, tooltip: "YouTube Brain")
        rebuildMenu(statusTitle: "YouTube Brain is ready", activeCount: 0)
        configureNotifications()
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
                setIconMode(.error, tooltip: "YouTube Brain needs attention")
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

        if let completed = newlyReady.first {
            announceCompletion(of: completed, additional: newlyReady.count - 1)
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

    // MARK: - Completion notification

    private func configureNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let openAction = UNNotificationAction(
            identifier: Self.openSummaryActionID,
            title: "Open Summary",
            options: [.foreground]
        )
        let telegraphAction = UNNotificationAction(
            identifier: Self.publishTelegraphActionID,
            title: "Share to Telegraph",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: Self.readyCategoryID,
            actions: [openAction, telegraphAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])

        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in
                self?.notificationsReady = granted
            }
        }
    }

    private func announceCompletion(of video: LibraryVideo, additional: Int) {
        guard notificationsReady else { return }

        let content = UNMutableNotificationContent()
        content.title = "Summary ready"
        if additional > 0 {
            content.subtitle = "\(video.displayTitle) (+\(additional) more)"
        } else {
            content.subtitle = video.displayTitle
        }
        content.body = video.isPublishedToTelegraph
            ? "Tap to open, or reopen the Telegraph page."
            : "Tap to open, or share it to Telegraph."
        content.sound = .default
        content.categoryIdentifier = Self.readyCategoryID
        content.userInfo = [
            "videoID": video.id,
            "summaryPath": video.summaryPath ?? "",
            "telegraphURL": video.telegraphURL ?? ""
        ]

        let request = UNNotificationRequest(
            identifier: "ready-\(video.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    private func openSummary(path: String) {
        guard !path.isEmpty else {
            openApp()
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func shareToTelegraph(videoID: String, existingURL: String) {
        if !existingURL.isEmpty, let url = URL(string: existingURL) {
            NSWorkspace.shared.open(url)
            return
        }
        Task {
            do {
                let response = try await service.publishTelegraph(videoID: videoID)
                if let url = URL(string: response.url) {
                    NSWorkspace.shared.open(url)
                }
            } catch {
                NSLog("youtube-brain: telegraph publish failed: %@", error.localizedDescription)
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

extension MenuBarController: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let videoID = userInfo["videoID"] as? String ?? ""
        let summaryPath = userInfo["summaryPath"] as? String ?? ""
        let telegraphURL = userInfo["telegraphURL"] as? String ?? ""
        let actionID = response.actionIdentifier

        Task { @MainActor in
            switch actionID {
            case Self.publishTelegraphActionID:
                self.shareToTelegraph(videoID: videoID, existingURL: telegraphURL)
            default:
                self.openSummary(path: summaryPath)
            }
            completionHandler()
        }
    }
}
