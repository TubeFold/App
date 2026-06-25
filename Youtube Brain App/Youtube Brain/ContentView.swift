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
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170)
        } detail: {
            switch selectedSection {
            case .library:
                LibraryView()
            case .settings:
                MainStatusView(viewModel: viewModel, showingSetup: $showingSetup)
            }
        }
        .task {
            await viewModel.loadState()
            showingSetup = viewModel.shouldPresentSetupOnLaunch
        }
        .onChange(of: viewModel.requiresCodexRepair) { _, needsRepair in
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
}

struct MainStatusView: View {
    @ObservedObject var viewModel: ProviderSetupViewModel
    @Binding var showingSetup: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("YouTube Brain")
                        .font(.largeTitle.weight(.semibold))
                    Text("Save clean Markdown summaries from YouTube videos using your local Codex account.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    viewModel.startRepair()
                    showingSetup = true
                } label: {
                    Label(viewModel.setupButtonTitle, systemImage: viewModel.requiresCodexRepair ? "wrench.and.screwdriver" : "sparkles")
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
                    title: "Codex",
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
                Text("Capture videos from the browser, then let YouTube Brain fetch the transcript, ask Codex for a summary, and save the result as Markdown.")
                    .font(.headline)
                Text("The local helper is started by the app when needed and stopped when the app quits.")
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 14) {
                Text("Codex Status")
                    .font(.headline)
                HStack(spacing: 12) {
                    StatusCheckItem(title: "Installed", isReady: viewModel.codexInstalled, detail: viewModel.codexVersionSummary)
                    StatusCheckItem(title: "Signed in", isReady: viewModel.codexSignedIn, detail: viewModel.codexSignedIn ? "Account verified" : "Test required")
                    StatusCheckItem(title: "Ready", isReady: viewModel.codexReady, detail: viewModel.codexReady ? "Summaries enabled" : "Setup incomplete")
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))

            CodexModelSettingsView(viewModel: viewModel)

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

struct CodexModelSettingsView: View {
    @ObservedObject var viewModel: ProviderSetupViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Codex Model")
                        .font(.headline)
                    Text("Used for new summaries. Existing Markdown files stay unchanged.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(viewModel.codexModelSummary)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 14) {
                Picker(
                    "Model",
                    selection: Binding(
                        get: { viewModel.selectedCodexModel },
                        set: { viewModel.updateCodexModel($0) }
                    )
                ) {
                    ForEach(viewModel.modelOptions) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                .frame(maxWidth: .infinity)

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
                .frame(width: 210)
            }
            .disabled(viewModel.isBusy)

            HStack(alignment: .top, spacing: 18) {
                SettingsHint(
                    title: viewModel.selectedModelOption?.label ?? viewModel.selectedCodexModel,
                    detail: viewModel.selectedModelOption?.description ?? "Selected Codex model."
                )
                SettingsHint(
                    title: viewModel.selectedReasoningEffortOption?.label ?? viewModel.selectedReasoningEffort,
                    detail: viewModel.selectedReasoningEffortOption?.description ?? "Selected reasoning effort."
                )
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
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
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

#Preview {
    ContentView()
}
