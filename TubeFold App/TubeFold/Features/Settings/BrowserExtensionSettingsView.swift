import SwiftUI

/// Soft install pitch for the companion Chrome extension. It appears only when
/// the extension hasn't been seen — once connected, the top status row shows an
/// "Extension · Connected" tile instead, so this card quietly disappears.
struct BrowserExtensionSettingsView: View {
    @ObservedObject var viewModel: ProviderSetupViewModel

    var body: some View {
        if !viewModel.extensionConnected {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Browser extension")
                        .font(.headline)
                    Text(
                        "Install the Chrome extension to send videos straight from a YouTube page — one click, no copy-paste.",
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Link(destination: TubeFoldLinks.chromeWebStore) {
                    Label("Get the Chrome extension", systemImage: "puzzlepiece.extension")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .settingsCard()
            .transition(.opacity)
        }
    }
}

#Preview {
    BrowserExtensionSettingsView(viewModel: ProviderSetupViewModel())
        .padding()
        .frame(width: 560)
}
