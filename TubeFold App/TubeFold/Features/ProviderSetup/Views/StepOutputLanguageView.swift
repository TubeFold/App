import SwiftUI

struct StepOutputLanguageView: View {
    @ObservedObject var viewModel: ProviderSetupViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Choose output language")
                .font(.largeTitle.weight(.semibold))

            Text("TubeFold will write summaries in this language. You can change it later in Settings.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                Label("Summary language", systemImage: "textformat")
                    .font(.headline)

                TextField("English", text: $viewModel.outputLanguageDraft)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .frame(maxWidth: 320)

                Text(
                    "You can specify any language here "
                        + "(examples: English, Español, Français, Polski, Русский, 简体中文).",
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .frame(maxWidth: 540, alignment: .leading)
    }
}

#Preview {
    StepOutputLanguageView(viewModel: ProviderSetupViewModel())
        .padding(34)
        .frame(width: 600, height: 480)
}
