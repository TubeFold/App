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
        .sheet(isPresented: $showingSetup) {
            ProviderSetupWizard(viewModel: viewModel, isPresented: $showingSetup)
                .frame(width: 820, height: 600)
        }
    }
}

enum AppSection: Hashable {
    case library
    case settings
    case about
}

struct MainStatusView: View {
    @ObservedObject var viewModel: ProviderSetupViewModel
    @Binding var showingSetup: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("TubeFold")
                        .font(.largeTitle.weight(.semibold))
                    Text("Save clean Markdown summaries from YouTube videos using your signed-in provider CLI.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    viewModel.startRepair()
                    showingSetup = true
                } label: {
                    Label(viewModel.setupButtonTitle, systemImage: viewModel.requiresRepair ? "wrench.and.screwdriver" : "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            HStack(spacing: 12) {
                StatusTile(
                    title: "App",
                    value: viewModel.apiReachable ? "Ready" : "Starting helper",
                    systemImage: viewModel.apiReachable ? "checkmark.circle.fill" : "clock.arrow.circlepath",
                    tint: viewModel.apiReachable ? .green : .orange
                )
                StatusTile(
                    title: viewModel.providerDisplayName,
                    value: viewModel.providerSummary,
                    systemImage: "terminal",
                    tint: .blue
                )
                StatusTile(
                    title: "Storage",
                    value: viewModel.outputDirectorySummary,
                    systemImage: "folder",
                    tint: .purple
                )
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Capture videos from the browser, then let TubeFold fetch the transcript, ask your provider for a summary, and save the result as Markdown.")
                    .font(.headline)
                Text("The local helper is started by the app when needed and stopped when the app quits.")
                    .foregroundStyle(.secondary)
            }
            .settingsCard()

            VStack(alignment: .leading, spacing: 16) {
                Text("\(viewModel.providerDisplayName) Status")
                    .font(.headline)
                HStack(alignment: .top, spacing: 12) {
                    StatusCheckItem(title: "Installed", isReady: viewModel.providerInstalled, detail: viewModel.versionSummary)
                    StatusCheckItem(title: "Signed in", isReady: viewModel.providerSignedIn, detail: viewModel.providerSignedIn ? "Account verified" : "Test required")
                    StatusCheckItem(title: "Ready", isReady: viewModel.providerReady, detail: viewModel.providerReady ? "Summaries enabled" : "Setup incomplete")
                }
            }
            .settingsCard()

            ProviderModelSettingsView(viewModel: viewModel)

            OutputLanguageSettingsView(viewModel: viewModel)

            UsageStatsView(viewModel: viewModel)

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
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Provider & Model")
                        .font(.headline)
                    Text("Used for new summaries. Existing Markdown files stay unchanged.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                Text(viewModel.modelSummary)
                    .font(.callout.weight(.semibold))
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
                    SettingsHint(
                        title: viewModel.selectedModelOption?.label ?? viewModel.selectedModel,
                        detail: viewModel.selectedModelOption?.description ?? "Selected model."
                    )
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
                    SettingsHint(
                        title: viewModel.selectedReasoningEffortOption?.label ?? viewModel.selectedReasoningEffort,
                        detail: viewModel.selectedReasoningEffortOption?.description ?? "Selected reasoning effort."
                    )
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

            if let weekly = usage.codexWeekly, let percent = weekly.usedPercent {
                weeklyGauge(percent: percent, resetsAt: weekly.resetsAt)
            }

            if usage.byProvider["claude"] != nil {
                SettingsHint(
                    title: "Claude weekly limit",
                    detail: "The Claude CLI doesn't report a weekly subscription percentage, so only spent tokens and cost are shown."
                )
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
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(UsageStatsView.formatTokens(usage.totalTokens)) tokens")
                    .font(.callout)
                    .monospacedDigit()
                if let cost = usage.costUsd, cost > 0 {
                    Text(String(format: "$%.2f", cost))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    @ViewBuilder
    private func weeklyGauge(percent: Double, resetsAt: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Codex weekly limit")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(Int(percent.rounded()))% used")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(percent >= 90 ? .red : .primary)
                    .monospacedDigit()
            }
            ProgressView(value: min(max(percent / 100, 0), 1))
                .tint(percent >= 90 ? .red : (percent >= 70 ? .orange : .blue))
            if let resets = UsageStatsView.formatReset(resetsAt) {
                Text(resets)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
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

    static func formatReset(_ resetsAt: Double?) -> String? {
        guard let resetsAt else { return nil }
        let remaining = resetsAt - Date().timeIntervalSince1970
        guard remaining > 0 else { return "Resets soon" }
        let days = Int(remaining) / 86_400
        let hours = (Int(remaining) % 86_400) / 3_600
        if days > 0 {
            return "Resets in \(days)d \(hours)h"
        }
        let minutes = (Int(remaining) % 3_600) / 60
        return hours > 0 ? "Resets in \(hours)h \(minutes)m" : "Resets in \(minutes)m"
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

struct SettingsHint: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(tint)
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
