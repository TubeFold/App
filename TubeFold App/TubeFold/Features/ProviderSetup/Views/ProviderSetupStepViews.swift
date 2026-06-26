import SwiftUI

struct StepIntroView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Connect Codex")
                .font(.largeTitle.weight(.semibold))
            Text("TubeFold uses your signed-in Codex CLI on this Mac. No API key is needed.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                Label("Before you continue", systemImage: "terminal")
                    .font(.headline)
                Text("Make sure Codex is installed and signed in. TubeFold will find it automatically, or you can choose the executable yourself.")
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: 540, alignment: .leading)
    }
}

struct StepInstallationView: View {
    @ObservedObject var viewModel: ProviderSetupViewModel
    @Binding var showingExecutablePicker: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Check Installation")
                .font(.largeTitle.weight(.semibold))
            Text("We look for Codex and verify the executable with a version check.")
                .foregroundStyle(.secondary)

            ProviderResultCard(
                title: "Codex CLI",
                status: viewModel.installationStatusTitle,
                message: viewModel.installationMessage,
                systemImage: viewModel.installationSucceeded ? "checkmark.circle.fill" : "terminal",
                tint: viewModel.installationSucceeded ? .green : .orange
            )

            HStack {
                Button {
                    Task { await viewModel.detectInstallation(path: nil) }
                } label: {
                    Label("Re-check", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isBusy)

                Button {
                    showingExecutablePicker = true
                } label: {
                    Label("Choose Executable", systemImage: "folder")
                }
                .disabled(viewModel.isBusy)
            }

            DetailsView(details: viewModel.installationDetails)
        }
        .frame(maxWidth: 600, alignment: .leading)
    }
}

struct StepConnectionView: View {
    @ObservedObject var viewModel: ProviderSetupViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Test Connection")
                .font(.largeTitle.weight(.semibold))
            Text("We ask Codex for a short fixed response to confirm it is signed in and ready.")
                .foregroundStyle(.secondary)

            ProviderResultCard(
                title: "Codex Account",
                status: viewModel.connectionStatusTitle,
                message: viewModel.connectionMessage,
                systemImage: viewModel.connectionSucceeded ? "checkmark.circle.fill" : "bolt.fill",
                tint: viewModel.connectionSucceeded ? .green : .orange
            )

            Button {
                Task { await viewModel.testConnection() }
            } label: {
                Label("Test Codex", systemImage: "bolt.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isBusy || !viewModel.installationSucceeded)

            DetailsView(details: viewModel.connectionDetails)
        }
        .frame(maxWidth: 600, alignment: .leading)
    }
}

struct StepCompleteView: View {
    @ObservedObject var viewModel: ProviderSetupViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("All set")
                .font(.largeTitle.weight(.semibold))
            Text("Codex is ready. You can reopen this setup any time from Settings.")
                .foregroundStyle(.secondary)
            ProviderResultCard(
                title: "Provider",
                status: "Ready",
                message: viewModel.providerSummary,
                systemImage: "sparkles",
                tint: .green
            )
        }
        .frame(maxWidth: 600, alignment: .leading)
    }
}
