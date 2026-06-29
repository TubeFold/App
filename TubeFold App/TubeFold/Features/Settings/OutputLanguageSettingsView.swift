import SwiftUI

struct OutputLanguageSettingsView: View {
    @ObservedObject var viewModel: ProviderSetupViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Output language")
                    .font(.headline)
                Text("The default language is English. You can specify any language here (examples: English, 简体中文, Español, 日本語, 한국어, Français). Applied to new summaries.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                TextField("English", text: $viewModel.outputLanguageDraft)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .frame(maxWidth: 320)
                    .onSubmit { viewModel.saveOutputLanguage() }

                Button {
                    viewModel.saveOutputLanguage()
                } label: {
                    if viewModel.outputLanguageDirty {
                        Text("Save").frame(minWidth: 56)
                    } else {
                        Label("Saved", systemImage: "checkmark")
                    }
                }
                .controlSize(.large)
                .disabled(!viewModel.outputLanguageDirty || viewModel.isBusy)

                Button("Reset") {
                    viewModel.resetOutputLanguage()
                }
                .controlSize(.large)
                .disabled(viewModel.isBusy)

                Spacer(minLength: 0)
            }
        }
        .settingsCard()
    }
}

#Preview {
    OutputLanguageSettingsView(viewModel: ProviderSetupViewModel())
        .padding()
        .frame(width: 560)
}
