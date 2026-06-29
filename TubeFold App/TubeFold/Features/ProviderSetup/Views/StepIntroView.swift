import SwiftUI

struct StepIntroView: View {
    @ObservedObject var viewModel: ProviderSetupViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Choose your provider")
                .font(.largeTitle.weight(.semibold))
            Text("TubeFold uses a signed-in CLI on this Mac to write summaries. Both options use your own subscription — no API key is needed.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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

            VStack(alignment: .leading, spacing: 10) {
                Label("Before you continue", systemImage: "terminal")
                    .font(.headline)
                Text("Make sure \(viewModel.providerDisplayName) is installed and signed in. TubeFold will find it automatically, or you can choose the executable yourself.")
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: 540, alignment: .leading)
    }
}

#Preview {
    StepIntroView(viewModel: ProviderSetupViewModel())
        .padding(34)
        .frame(width: 600, height: 480)
}
