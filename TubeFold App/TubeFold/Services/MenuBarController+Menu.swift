import AppKit
import Foundation

/// The status-item dropdown menu and its actions.
extension MenuBarController {
    func rebuildMenu(statusTitle: String) {
        lastStatusTitle = statusTitle
        let menu = NSMenu()

        let status = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: String(localized: "Open Library"),
            action: #selector(openApp),
            keyEquivalent: "",
        ))

        menu.addItem(.separator())
        latestSummaryMenuItems().forEach(menu.addItem)

        menu.addItem(.separator())

        let checkForUpdates = NSMenuItem(
            title: String(localized: "Check for Updates…"),
            action: #selector(checkForUpdatesFromMenu),
            keyEquivalent: "",
        )
        checkForUpdates.isEnabled = UpdaterController.shared.canCheckForUpdates
        menu.addItem(checkForUpdates)

        // Only surface the install link to people who don't already have the extension.
        if !extensionConnected {
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(
                title: String(localized: "Get the Chrome Extension…"),
                action: #selector(openChromeStore),
                keyEquivalent: "",
            ))
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: String(localized: "Quit TubeFold"),
            action: #selector(quitApp),
            keyEquivalent: "q",
        ))

        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    /// The three "Open Latest Summary" flavors (Markdown / PDF / Web).
    private func latestSummaryMenuItems() -> [NSMenuItem] {
        let openSummary = NSMenuItem(
            title: String(localized: "Open Latest Summary (Markdown)"),
            action: #selector(openLatestSummary),
            keyEquivalent: "",
        )
        openSummary.isEnabled = lastReadyVideo?.markdownURL != nil

        let openSummaryPDF = NSMenuItem(
            title: String(localized: "Open Latest Summary (PDF)"),
            action: #selector(openLatestSummaryPDF),
            keyEquivalent: "",
        )
        openSummaryPDF.isEnabled = lastReadyVideo?.markdownURL != nil && pdfRenderingVideoID == nil

        let openSummaryWeb = NSMenuItem(
            title: String(localized: "Open Latest Summary (Web)"),
            action: #selector(openLatestSummaryWeb),
            keyEquivalent: "",
        )
        openSummaryWeb.isEnabled = lastReadyVideo != nil && publishingVideoID == nil

        return [openSummary, openSummaryPDF, openSummaryWeb]
    }

    @objc private func openApp() {
        AppDelegate.showMainWindow()
    }

    @objc private func openLatestSummary() {
        guard let url = lastReadyVideo?.markdownURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Render the latest summary to PDF and open it in the default viewer, mirroring
    /// the Library row's "Open PDF" action. Best-effort; a render failure is logged.
    @objc private func openLatestSummaryPDF() {
        guard pdfRenderingVideoID == nil,
              let video = lastReadyVideo,
              let sourceURL = video.markdownURL,
              let markdown = try? String(contentsOf: sourceURL, encoding: .utf8) else { return }
        pdfRenderingVideoID = video.id
        Task {
            defer {
                pdfRenderingVideoID = nil
                rebuildMenu(statusTitle: lastStatusTitle)
            }
            do {
                let data = try await SummaryPDFRenderer().makePDFData(markdown: markdown, title: video.displayTitle)
                let fileURL = LibraryViewModel.renderedArtifactURL(
                    for: video,
                    sourceURL: sourceURL,
                    fileExtension: "pdf",
                )
                try data.write(to: fileURL)
                NSWorkspace.shared.open(fileURL)
            } catch {
                NSLog("tubefold: latest-summary PDF render failed: %@", error.localizedDescription)
            }
        }
        rebuildMenu(statusTitle: lastStatusTitle)
    }

    /// Publish the latest summary to Telegraph (if needed) and open the web page,
    /// reusing the same publish-then-open flow as auto-open.
    @objc private func openLatestSummaryWeb() {
        guard publishingVideoID == nil, let video = lastReadyVideo else { return }
        if let existing = video.telegraphURL, !existing.isEmpty, let url = URL(string: existing) {
            NSWorkspace.shared.open(url)
            return
        }
        publishingVideoID = video.id
        Task {
            defer {
                publishingVideoID = nil
                rebuildMenu(statusTitle: lastStatusTitle)
            }
            do {
                let response = try await service.publishTelegraph(videoID: video.id)
                if let url = URL(string: response.url) {
                    NSWorkspace.shared.open(url)
                }
            } catch {
                NSLog("tubefold: latest-summary Telegraph publish failed: %@", error.localizedDescription)
            }
        }
        rebuildMenu(statusTitle: lastStatusTitle)
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
}
