import SwiftUI

struct StepInstallationView: View {
    @ObservedObject var viewModel: ProviderSetupViewModel
    @Binding var showingExecutablePicker: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Check Installation")
                .font(.largeTitle.weight(.semibold))
            Text("We look for \(viewModel.providerDisplayName) and verify the executable with a version check.")
                .foregroundStyle(.secondary)

            ProviderResultCardView(
                title: viewModel.providerDisplayName,
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
                .help("Pick the \(viewModel.providerDisplayName) executable manually")
            }

            DetailsView(details: viewModel.installationDetails)
        }
        .frame(maxWidth: 600, alignment: .leading)
    }
}
