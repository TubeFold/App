import SwiftUI

struct StepConnectionView: View {
    @ObservedObject var viewModel: ProviderSetupViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Test Connection")
                .font(.largeTitle.weight(.semibold))
            Text(
                "We ask \(viewModel.providerDisplayName) for a short fixed response to confirm it is signed in and ready.",
            )
            .foregroundStyle(.secondary)

            ProviderResultCardView(
                title: "\(viewModel.providerDisplayName) Account",
                status: viewModel.connectionStatusTitle,
                message: viewModel.connectionMessage,
                systemImage: viewModel.connectionSucceeded ? "checkmark.circle.fill" : "bolt.fill",
                tint: viewModel.connectionSucceeded ? .green : .orange,
            )

            Button {
                Task { await viewModel.testConnection() }
            } label: {
                Label("Test Connection", systemImage: "bolt.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isBusy || !viewModel.installationSucceeded)

            DetailsView(details: viewModel.connectionDetails)
        }
        .frame(maxWidth: 600, alignment: .leading)
    }
}

#Preview {
    StepConnectionView(viewModel: ProviderSetupViewModel())
        .padding(34)
        .frame(width: 660, height: 480)
}
