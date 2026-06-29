import SwiftUI

struct StepCompleteView: View {
    @ObservedObject var viewModel: ProviderSetupViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("All set")
                .font(.largeTitle.weight(.semibold))
            Text("\(viewModel.providerDisplayName) is ready. You can reopen this setup any time from Settings.")
                .foregroundStyle(.secondary)
            ProviderResultCardView(
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
