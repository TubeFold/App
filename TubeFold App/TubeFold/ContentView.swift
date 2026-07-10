import AppKit
import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ProviderSetupViewModel()
    @State private var showingSetup = false
    @State private var selectedSection: AppSection = .library

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedSection) {
                Label("Library", systemImage: "play.rectangle")
                    .tag(AppSection.library)
                Label("Settings", systemImage: "gearshape")
                    .tag(AppSection.settings)
                Label("About", systemImage: "info.circle")
                    .tag(AppSection.about)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170)
        } detail: {
            switch selectedSection {
            case .library:
                LibraryView()
            case .settings:
                MainStatusView(viewModel: viewModel, showingSetup: $showingSetup)
            case .about:
                AboutView()
            }
        }
        .task {
            await viewModel.loadState()
            showingSetup = viewModel.shouldPresentSetupOnLaunch
        }
        .onChange(of: viewModel.requiresRepair) { _, needsRepair in
            if needsRepair, !showingSetup {
                viewModel.startRepair()
                showingSetup = true
            }
        }
        .onChange(of: selectedSection) { _, section in
            // Refresh usage stats and the extension tile every time the user
            // opens Settings — the extension may have connected since launch.
            if section == .settings {
                Task {
                    await viewModel.refreshProviderInstallation()
                    await viewModel.refreshUsage()
                    await viewModel.refreshExtensionStatus()
                }
            }
        }
        .sheet(isPresented: $showingSetup) {
            ProviderSetupWizardView(viewModel: viewModel, isPresented: $showingSetup)
                .frame(width: 820, height: 600)
        }
        // Library's detail root is a plain VStack, so AppKit always draws the
        // titlebar hairline under it. Settings/About use a ScrollView root, where
        // the separator is tied to scroll position and hidden at the top. Force
        // `.none` on Library for a clean top edge that matches the other sections;
        // keep `.automatic` elsewhere so their on-scroll separator still appears.
        .background(
            TitlebarSeparatorStyleSetter(
                style: selectedSection == .library ? .none : .automatic,
            ),
        )
    }
}

/// Sets the host window's titlebar separator style. There's no SwiftUI modifier
/// for this, so reach the `NSWindow` through a zero-size representable.
private struct TitlebarSeparatorStyleSetter: NSViewRepresentable {
    let style: NSTitlebarSeparatorStyle

    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        apply(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        apply(from: nsView)
    }

    private func apply(from view: NSView) {
        let style = style
        // The window isn't attached yet on the first pass; defer to the next runloop.
        DispatchQueue.main.async { view.window?.titlebarSeparatorStyle = style }
    }
}

enum AppSection: Hashable {
    case library
    case settings
    case about
}

/// Shared external links used across the app's surfaces.
enum TubeFoldLinks {
    static let chromeWebStore =
        URL(
            string: "https://chromewebstore.google.com/detail/tubefold-mac-app-companio/hjfcdpioihmgoccmfkcicofjgbkjidbh",
        )!
}

/// Whether the Chrome extension has recently talked to the local backend.
/// Drives the gentle "install the extension" nudges — they only appear when it
/// hasn't been seen, so people who already have it never get advertised to.
struct ExtensionStatus: Decodable {
    let connected: Bool
    let lastSeenAt: String?
}

#Preview {
    ContentView()
}
