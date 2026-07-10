import SwiftUI

struct MainStatusView: View {
    @ObservedObject var viewModel: ProviderSetupViewModel
    @Binding var showingSetup: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("\(viewModel.providerDisplayName) Status")
                        .font(.headline)
                    HStack(alignment: .top, spacing: 12) {
                        StatusCheckItemView(
                            title: viewModel.providerInstallationStatusTitle,
                            isReady: viewModel.providerInstalled,
                            detail: viewModel.versionSummary,
                            isWarning: viewModel.providerUpdateAvailable,
                        )
                        StatusCheckItemView(
                            title: "Signed in",
                            isReady: viewModel.providerSignedIn,
                            detail: viewModel.providerSignedIn ? "Account verified" : "Test required",
                        )
                        StatusCheckItemView(
                            title: "Ready",
                            isReady: viewModel.providerReady,
                            detail: viewModel.providerReady ? "Summaries enabled" : "Setup incomplete",
                        )
                    }

                    HStack {
                        Button {
                            viewModel.startRepair()
                            showingSetup = true
                        } label: {
                            Label(
                                viewModel.setupButtonTitle,
                                systemImage: viewModel.requiresRepair ? "wrench.and.screwdriver" : "sparkles",
                            )
                        }
                        .controlSize(.large)

                        if viewModel.providerUpdateAvailable {
                            Button {
                                viewModel.copyProviderUpdateCommand()
                            } label: {
                                if viewModel.providerUpdateCommandCopied {
                                    Label("Copied", systemImage: "checkmark")
                                } else {
                                    Label("Copy codex update", systemImage: "doc.on.doc")
                                }
                            }
                            .controlSize(.large)
                            .help("Copy “codex update” to the clipboard")
                        }

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
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }

                Spacer()
            }
            .padding(32)
            // The extension card removes itself once the extension connects;
            // let the section collapse smoothly rather than jump.
            .animation(.smooth(duration: 0.3), value: viewModel.extensionConnected)
            .animation(.smooth(duration: 0.25), value: viewModel.errorMessage)
        }
        .navigationTitle("Settings")
    }
}

#Preview {
    MainStatusView(viewModel: ProviderSetupViewModel(), showingSetup: .constant(false))
        .frame(width: 640, height: 700)
}
