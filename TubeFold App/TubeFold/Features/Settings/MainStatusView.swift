import SwiftUI

struct MainStatusView: View {
    @ObservedObject var viewModel: ProviderSetupViewModel
    @Binding var showingSetup: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 12) {
                StatusTileView(
                    title: "App",
                    value: viewModel.apiReachable ? "Ready" : "Starting helper",
                    systemImage: "macwindow",
                    tint: viewModel.apiReachable ? .indigo : .orange
                )
                StatusTileView(
                    title: viewModel.providerDisplayName,
                    value: viewModel.providerSummary,
                    systemImage: "terminal",
                    tint: .blue
                )
                if viewModel.extensionConnected {
                    StatusTileView(
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
                    StatusCheckItemView(title: "Installed", isReady: viewModel.providerInstalled, detail: viewModel.versionSummary)
                    StatusCheckItemView(title: "Signed in", isReady: viewModel.providerSignedIn, detail: viewModel.providerSignedIn ? "Account verified" : "Test required")
                    StatusCheckItemView(title: "Ready", isReady: viewModel.providerReady, detail: viewModel.providerReady ? "Summaries enabled" : "Setup incomplete")
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

#Preview {
    MainStatusView(viewModel: ProviderSetupViewModel(), showingSetup: .constant(false))
        .frame(width: 640, height: 700)
}
