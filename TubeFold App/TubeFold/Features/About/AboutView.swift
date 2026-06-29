import AppKit
import SwiftUI

/// The "About" section: app identity, version, useful links, and the Sparkle
/// auto-update controls (the toggle + manual check live here so everything that
/// touches updates is in one place).
struct AboutView: View {
    @ObservedObject private var updater = UpdaterController.shared

    private static let links: [AboutLink] = [
        AboutLink(title: "GitHub", systemImage: "chevron.left.forwardslash.chevron.right", url: "https://github.com/TubeFold/App"),
        AboutLink(title: "Website", systemImage: "globe", url: "https://tubefold.github.io/"),
        AboutLink(title: "Chrome extension", systemImage: "puzzlepiece.extension", url: "https://chromewebstore.google.com/detail/tubefold-mac-app-companio/hjfcdpioihmgoccmfkcicofjgbkjidbh"),
        AboutLink(title: "Report an issue", systemImage: "exclamationmark.bubble", url: "https://github.com/TubeFold/App/issues"),
        AboutLink(title: "Feedback", systemImage: "envelope", url: "mailto:tubefold@proton.me"),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)

                VStack(spacing: 6) {
                    Text(AboutInfo.appName)
                        .font(.title.weight(.semibold))
                    Text(AboutInfo.versionLine)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 10) {
                    ForEach(Self.links) { link in
                        Link(destination: URL(string: link.url)!) {
                            Label(link.title, systemImage: link.systemImage)
                                .font(.callout.weight(.medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    }
                }
                .padding(.top, 4)

                Divider()
                    .padding(.horizontal, 40)

                VStack(spacing: 12) {
                    Toggle("Check for updates automatically", isOn: $updater.automaticallyChecksForUpdates)
                        .toggleStyle(.checkbox)

                    Button("Check for Updates…") {
                        updater.checkForUpdates()
                    }
                    .controlSize(.large)
                    .disabled(!updater.canCheckForUpdates)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .padding(.horizontal, 32)
        }
        .navigationTitle("About")
    }
}

private struct AboutLink: Identifiable {
    let title: String
    let systemImage: String
    let url: String
    var id: String { title }
}

/// Static facts pulled from the bundle so the screen never drifts from the build.
enum AboutInfo {
    static let appName = "TubeFold"

    static var versionLine: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "Version \(short) (\(build))"
    }
}

#Preview {
    AboutView()
        .frame(width: 520, height: 720)
}
