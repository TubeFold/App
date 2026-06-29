import SwiftUI

struct StorageSettingsView: View {
    @ObservedObject var viewModel: ProviderSetupViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Storage")
                    .font(.headline)
                Text("Summaries are saved here as Markdown files. Open the folder to browse, move, or back them up.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Label(viewModel.outputDirectorySummary, systemImage: "folder")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack {
                Button {
                    viewModel.revealOutputDirectory()
                } label: {
                    Label("Show in Finder", systemImage: "arrow.up.forward.app")
                }
                .controlSize(.large)

                Spacer(minLength: 0)
            }
        }
        .settingsCard()
    }
}
