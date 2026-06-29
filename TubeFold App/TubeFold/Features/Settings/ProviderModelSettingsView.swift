import SwiftUI

struct ProviderModelSettingsView: View {
    @ObservedObject var viewModel: ProviderSetupViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Provider & Model")
                    .font(.headline)
                Text("Used for new summaries. Existing Markdown files stay unchanged.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsFieldLabelView("Provider")
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
                    SettingsFieldLabelView("Model")
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
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    SettingsFieldLabelView("Effort")
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
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(viewModel.isBusy)
        }
        .settingsCard()
    }
}

#Preview {
    ProviderModelSettingsView(viewModel: ProviderSetupViewModel())
        .padding()
        .frame(width: 560)
}
