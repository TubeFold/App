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
            if needsRepair {
                viewModel.startRepair()
                showingSetup = true
            }
        }
        .onChange(of: selectedSection) { _, section in
            // Refresh usage stats every time the user opens Settings.
            if section == .settings {
                Task { await viewModel.refreshUsage() }
            }
        }
        .sheet(isPresented: $showingSetup) {
            ProviderSetupWizard(viewModel: viewModel, isPresented: $showingSetup)
                .frame(width: 820, height: 600)
        }
        // Library's detail root is a plain VStack, so AppKit always draws the
        // titlebar hairline under it. Settings/About use a ScrollView root, where
        // the separator is tied to scroll position and hidden at the top. Force
        // `.none` on Library for a clean top edge that matches the other sections;
        // keep `.automatic` elsewhere so their on-scroll separator still appears.
        .background(
            TitlebarSeparatorStyleSetter(
                style: selectedSection == .library ? .none : .automatic
            )
        )
    }
}

/// Sets the host window's titlebar separator style. There's no SwiftUI modifier
/// for this, so reach the `NSWindow` through a zero-size representable.
private struct TitlebarSeparatorStyleSetter: NSViewRepresentable {
    let style: NSTitlebarSeparatorStyle

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        apply(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
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
    static let chromeWebStore = URL(string: "https://chromewebstore.google.com/detail/tubefold-mac-app-companio/hjfcdpioihmgoccmfkcicofjgbkjidbh")!
}

/// Whether the Chrome extension has recently talked to the local backend.
/// Drives the gentle "install the extension" nudges — they only appear when it
/// hasn't been seen, so people who already have it never get advertised to.
struct ExtensionStatus: Decodable {
    let connected: Bool
    let lastSeenAt: String?
}

struct MainStatusView: View {
    @ObservedObject var viewModel: ProviderSetupViewModel
    @Binding var showingSetup: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 12) {
                StatusTile(
                    title: "App",
                    value: viewModel.apiReachable ? "Ready" : "Starting helper",
                    systemImage: "macwindow",
                    tint: viewModel.apiReachable ? .indigo : .orange
                )
                StatusTile(
                    title: viewModel.providerDisplayName,
                    value: viewModel.providerSummary,
                    systemImage: "terminal",
                    tint: .blue
                )
                if viewModel.extensionConnected {
                    StatusTile(
                        title: "Extension",
                        value: "Connected",
                        systemImage: "puzzlepiece.extension",
                        tint: .pink
                    )
                }
            }

            VStack(alignment: .leading, spacing: 16) {
                Text("\(viewModel.providerDisplayName) Status")
                    .font(.headline)
                HStack(alignment: .top, spacing: 12) {
                    StatusCheckItem(title: "Installed", isReady: viewModel.providerInstalled, detail: viewModel.versionSummary)
                    StatusCheckItem(title: "Signed in", isReady: viewModel.providerSignedIn, detail: viewModel.providerSignedIn ? "Account verified" : "Test required")
                    StatusCheckItem(title: "Ready", isReady: viewModel.providerReady, detail: viewModel.providerReady ? "Summaries enabled" : "Setup incomplete")
                }

                HStack {
                    Button {
                        viewModel.startRepair()
                        showingSetup = true
                    } label: {
                        Label(viewModel.setupButtonTitle, systemImage: viewModel.requiresRepair ? "wrench.and.screwdriver" : "sparkles")
                    }
                    .controlSize(.large)

                    Spacer(minLength: 0)
                }
            }
            .settingsCard()

            BrowserExtensionSettingsView(viewModel: viewModel)

            ProviderModelSettingsView(viewModel: viewModel)

            OutputLanguageSettingsView(viewModel: viewModel)

            AppBehaviorSettingsView()

            UsageStatsView(viewModel: viewModel)

            StorageSettingsView(viewModel: viewModel)

            ResetDataSettingsView(viewModel: viewModel)

            if let errorMessage = viewModel.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
            }
            .padding(32)
        }
        .navigationTitle("Settings")
    }
}

struct ProviderModelSettingsView: View {
    @ObservedObject var viewModel: ProviderSetupViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Provider & Model")
                    .font(.headline)
                Text("Used for new summaries. Existing Markdown files stay unchanged.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsFieldLabel("Provider")
                Picker(
                    "Provider",
                    selection: Binding(
                        get: { viewModel.selectedProviderID },
                        set: { newValue in Task { await viewModel.selectProvider(newValue) } }
                    )
                ) {
                    ForEach(viewModel.availableProviders) { provider in
                        Text(provider.displayName).tag(provider.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            .disabled(viewModel.isBusy)

            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    SettingsFieldLabel("Model")
                    Picker(
                        "Model",
                        selection: Binding(
                            get: { viewModel.selectedModel },
                            set: { viewModel.updateModel($0) }
                        )
                    ) {
                        ForEach(viewModel.modelOptions) { option in
                            Text(option.label).tag(option.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    SettingsFieldLabel("Effort")
                    Picker(
                        "Effort",
                        selection: Binding(
                            get: { viewModel.selectedReasoningEffort },
                            set: { viewModel.updateReasoningEffort($0) }
                        )
                    ) {
                        ForEach(viewModel.reasoningEffortOptions) { option in
                            Text(option.label).tag(option.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(viewModel.isBusy)
        }
        .settingsCard()
    }
}

struct OutputLanguageSettingsView: View {
    @ObservedObject var viewModel: ProviderSetupViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Output language")
                    .font(.headline)
                Text("The default language is English. You can specify any language here (examples: English, 简体中文, Español, 日本語, 한국어, Français). Applied to new summaries.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                TextField("English", text: $viewModel.outputLanguageDraft)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .frame(maxWidth: 320)
                    .onSubmit { viewModel.saveOutputLanguage() }

                Button {
                    viewModel.saveOutputLanguage()
                } label: {
                    if viewModel.outputLanguageDirty {
                        Text("Save").frame(minWidth: 56)
                    } else {
                        Label("Saved", systemImage: "checkmark")
                    }
                }
                .controlSize(.large)
                .disabled(!viewModel.outputLanguageDirty || viewModel.isBusy)

                Button("Reset") {
                    viewModel.resetOutputLanguage()
                }
                .controlSize(.large)
                .disabled(viewModel.isBusy)

                Spacer(minLength: 0)
            }
        }
        .settingsCard()
    }
}

struct AppBehaviorSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("App behavior")
                    .font(.headline)
                Text("Control how TubeFold reacts when a summary finishes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle(isOn: $settings.autoOpenTelegraph) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open Telegraph automatically")
                    Text("When a summary is ready, publish it to Telegraph and open the page in your browser.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Toggle(isOn: $settings.hideMenuBarIcon) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hide menu bar icon")
                    Text("Remove the TubeFold icon from the macOS menu bar. The main window stays available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .settingsCard()
    }
}

/// Soft install pitch for the companion Chrome extension. It appears only when
/// the extension hasn't been seen — once connected, the top status row shows an
/// "Extension · Connected" tile instead, so this card quietly disappears.
struct BrowserExtensionSettingsView: View {
    @ObservedObject var viewModel: ProviderSetupViewModel

    var body: some View {
        if !viewModel.extensionConnected {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Browser extension")
                        .font(.headline)
                    Text("Install the Chrome extension to send videos straight from a YouTube page — one click, no copy-paste.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Link(destination: TubeFoldLinks.chromeWebStore) {
                    Label("Get the Chrome extension", systemImage: "puzzlepiece.extension")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .settingsCard()
        }
    }
}

struct UsageStatsView: View {
    @ObservedObject var viewModel: ProviderSetupViewModel

    private var usage: UsageSummary { viewModel.usage ?? .empty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Usage")
                        .font(.headline)
                    Text("Tokens TubeFold has spent analyzing videos with your provider CLI.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Button {
                    Task { await viewModel.refreshUsage() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh usage")
            }

            if usage.totalTokens == 0 {
                Text("No analyses recorded yet. Token usage appears here after your first summary.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(UsageStatsView.formatTokens(usage.totalTokens))
                        .font(.system(.title, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                    Text("tokens total")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                ForEach(usage.sortedProviders, id: \.name) { entry in
                    providerRow(name: entry.name, usage: entry.usage)
                }
            }
        }
        .settingsCard()
    }

    @ViewBuilder
    private func providerRow(name: String, usage: UsageSummary.ProviderUsage) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(UsageStatsView.providerDisplayName(name))
                .font(.subheadline.weight(.semibold))
            Text("\(usage.jobs) \(usage.jobs == 1 ? "run" : "runs")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text("\(UsageStatsView.formatTokens(usage.totalTokens)) tokens")
                .font(.callout)
                .monospacedDigit()
        }
    }

    static func providerDisplayName(_ id: String) -> String {
        switch id {
        case "codex": return "Codex CLI"
        case "claude": return "Claude Code CLI"
        default: return id.capitalized
        }
    }

    static func formatTokens(_ tokens: Int) -> String {
        let value = Double(tokens)
        if value >= 1_000_000 {
            return String(format: "%.1fM", value / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", value / 1_000)
        }
        return String(tokens)
    }
}

struct StorageSettingsView: View {
    @ObservedObject var viewModel: ProviderSetupViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Storage")
                    .font(.headline)
                Text("Summaries are saved here as Markdown files. Open the folder to browse, move, or back them up.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Label(viewModel.outputDirectorySummary, systemImage: "folder")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack {
                Button {
                    viewModel.revealOutputDirectory()
                } label: {
                    Label("Show in Finder", systemImage: "arrow.up.forward.app")
                }
                .controlSize(.large)

                Spacer(minLength: 0)
            }
        }
        .settingsCard()
    }
}

struct ResetDataSettingsView: View {
    @ObservedObject var viewModel: ProviderSetupViewModel
    @State private var showingConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Reset")
                    .font(.headline)
                Text("Erase the whole library, processing history, and usage stats so the app starts from scratch. Your provider sign-in and settings are kept. This can't be undone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(role: .destructive) {
                    showingConfirmation = true
                } label: {
                    Label("Clear all data", systemImage: "trash")
                }
                .controlSize(.large)
                .disabled(viewModel.isBusy)

                Spacer(minLength: 0)
            }
        }
        .settingsCard()
        .confirmationDialog(
            "Clear all data?",
            isPresented: $showingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear all data", role: .destructive) {
                Task { await viewModel.resetData() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every saved summary, queued job, and usage record will be permanently removed. Your provider sign-in and settings stay intact.")
        }
    }
}

/// Small uppercase caption used to label a form control.
struct SettingsFieldLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.5)
            .foregroundStyle(.secondary)
    }
}

struct StatusCheckItem: View {
    let title: String
    let isReady: Bool
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isReady ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isReady ? .green : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct StatusTile: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color
    /// When set, the tile becomes clickable and runs this on tap.
    var action: (() -> Void)? = nil

    @State private var isHovering = false

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(value)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    var body: some View {
        if let action {
            Button(action: action) {
                content
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(tint.opacity(isHovering ? 0.6 : 0), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .help("Open in Finder")
        } else {
            content
        }
    }
}

private extension View {
    /// Consistent card chrome for every Settings section.
    func settingsCard() -> some View {
        self
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

#Preview {
    ContentView()
}
