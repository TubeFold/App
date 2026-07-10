import SwiftUI

/// Settings card listing every article this Mac's Telegraph account has
/// published, fetched live via `getPageList`. Rows open in the browser.
struct TelegraphArticlesSettingsView: View {
    @ObservedObject var viewModel: ProviderSetupViewModel
    @State private var confirmingNewAccount = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Telegraph articles")
                        .font(.headline)
                    Text("Summaries TubeFold has published to telegra.ph from this Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let account = viewModel.telegraphAccount {
                        Text("Account: \(account)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                            .help("The Telegraph account TubeFold publishes under. It lives only on this Mac (telegraph-account.json).")
                    }
                }
                Spacer(minLength: 16)
                Button {
                    Task { await viewModel.refreshTelegraphPages() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh articles")
            }

            if let pages = viewModel.telegraphPages, !pages.isEmpty {
                ForEach(pages) { page in
                    pageRow(page)
                }
            } else {
                Text("No articles yet. Publish a summary with “Read in Telegraph” and it will show up here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if viewModel.telegraphAccount != nil {
                HStack {
                    Button(role: .destructive) {
                        confirmingNewAccount = true
                    } label: {
                        Label("Reset account", systemImage: "person.crop.circle.badge.xmark")
                    }
                    .controlSize(.large)
                    .disabled(viewModel.isBusy)

                    Spacer(minLength: 0)
                }
            }
        }
        .settingsCard()
        .confirmationDialog(
            "Reset Telegraph account?",
            isPresented: $confirmingNewAccount,
            titleVisibility: .visible,
        ) {
            Button("Reset account", role: .destructive) {
                Task { await viewModel.regenerateTelegraphAccount() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("New summaries will be published under a fresh account. Articles already published stay online, but TubeFold can no longer update them.")
        }
    }

    private func pageRow(_ page: TelegraphPage) -> some View {
        HStack(alignment: .firstTextBaseline) {
            if let url = URL(string: page.url) {
                Link(page.title, destination: url)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(page.url)
            } else {
                Text(page.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Text("\(page.views) views")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

#Preview {
    TelegraphArticlesSettingsView(viewModel: ProviderSetupViewModel())
        .padding()
        .frame(width: 560)
}
