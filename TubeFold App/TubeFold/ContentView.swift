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
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 14) {
                Text("\(viewModel.providerDisplayName) Status")
                    .font(.headline)
                HStack(spacing: 12) {
                    StatusCheckItem(title: "Installed", isReady: viewModel.providerInstalled, detail: viewModel.versionSummary)
                    StatusCheckItem(title: "Signed in", isReady: viewModel.providerSignedIn, detail: viewModel.providerSignedIn ? "Account verified" : "Test required")
                    StatusCheckItem(title: "Ready", isReady: viewModel.providerReady, detail: viewModel.providerReady ? "Summaries enabled" : "Setup incomplete")
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))

            ProviderModelSettingsView(viewModel: viewModel)

            OutputLanguageSettingsView(viewModel: viewModel)

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
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Provider & Model")
                        .font(.headline)
                    Text("Used for new summaries. Existing Markdown files stay unchanged.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(viewModel.modelSummary)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

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
            .pickerStyle(.segmented)
            .disabled(viewModel.isBusy)

            HStack(alignment: .top, spacing: 14) {
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
                    title: viewModel.selectedModelOption?.label ?? viewModel.selectedModel,
                    detail: viewModel.selectedModelOption?.description ?? "Selected model."
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

struct OutputLanguageSettingsView: View {
    @ObservedObject var viewModel: ProviderSetupViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Output language")
                    .font(.headline)
                Text("The default language is English. You can specify any language here (examples: English, 简体中文, Español, 日本語, 한국어, Français). Applied to new summaries.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                TextField("English", text: $viewModel.outputLanguageDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .onSubmit { viewModel.saveOutputLanguage() }

                Button {
                    viewModel.saveOutputLanguage()
                } label: {
                    if viewModel.outputLanguageDirty {
                        Text("Save")
                    } else {
                        Label("Saved", systemImage: "checkmark")
                    }
                }
                .disabled(!viewModel.outputLanguageDirty || viewModel.isBusy)

                Button("Reset") {
                    viewModel.resetOutputLanguage()
                }
                .disabled(viewModel.isBusy)
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
