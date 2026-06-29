import SwiftUI

struct ResetDataSettingsView: View {
    @ObservedObject var viewModel: ProviderSetupViewModel
    @State private var showingConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Reset")
                    .font(.headline)
                Text("Erase the whole library, processing history, and usage stats so the app starts from scratch. Your provider sign-in and settings are kept. This can't be undone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(role: .destructive) {
                    showingConfirmation = true
                } label: {
                    Label("Clear all data", systemImage: "trash")
                }
                .controlSize(.large)
                .disabled(viewModel.isBusy)

                Spacer(minLength: 0)
            }
        }
        .settingsCard()
        .confirmationDialog(
            "Clear all data?",
            isPresented: $showingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear all data", role: .destructive) {
                Task { await viewModel.resetData() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every saved summary, queued job, and usage record will be permanently removed. Your provider sign-in and settings stay intact.")
        }
    }
}

#Preview {
    ResetDataSettingsView(viewModel: ProviderSetupViewModel())
        .padding()
        .frame(width: 560)
}
