import SwiftUI

struct ResetDataSettingsView: View {
    @ObservedObject var viewModel: ProviderSetupViewModel
    @State private var showingConfirmation = false
    @State private var showingFirstRunConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Reset")
                    .font(.headline)
                Text(
                    "Erase the whole library, processing history, and usage stats so the app starts from scratch. Your provider sign-in and settings are kept. This can't be undone.",
                )
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

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Testing")
                    .font(.headline)
                Text(
                    "Return TubeFold to the first-launch state so you can retest provider setup and first entry. The app quits after the reset.",
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(role: .destructive) {
                    showingFirstRunConfirmation = true
                } label: {
                    Label("Reset first-run setup", systemImage: "arrow.counterclockwise.circle")
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
            titleVisibility: .visible,
        ) {
            Button("Clear all data", role: .destructive) {
                Task { await viewModel.resetData() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Every saved summary, queued job, and usage record will be permanently removed. Your provider sign-in and settings stay intact.",
            )
        }
        .confirmationDialog(
            "Reset first-run setup?",
            isPresented: $showingFirstRunConfirmation,
            titleVisibility: .visible,
        ) {
            Button("Reset and quit", role: .destructive) {
                Task {
                    await viewModel.resetFirstRunState(quitAfterReset: true)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This clears the library, provider setup, extension state, usage history, and app behavior flags. TubeFold will quit automatically so the next launch tests the real first-launch setup behavior. Telegraph account data is left alone.",
            )
        }
    }
}

#Preview {
    ResetDataSettingsView(viewModel: ProviderSetupViewModel())
        .padding()
        .frame(width: 560)
}
