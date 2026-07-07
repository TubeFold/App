import SwiftUI

struct StepIntroView: View {
    @ObservedObject var viewModel: ProviderSetupViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Choose provider")
                .font(.largeTitle.weight(.semibold))

            VStack(spacing: 10) {
                ForEach(viewModel.availableProviders) { provider in
                    ProviderAccountChoiceView(
                        providerID: provider.id,
                        title: viewModel.providerAccountName(for: provider.id),
                        subtitle: viewModel.providerAccountSubtitle(for: provider.id),
                        isSelected: viewModel.selectedProviderID == provider.id,
                    ) {
                        Task { await viewModel.selectProvider(provider.id) }
                    }
                }
            }
            .disabled(viewModel.isBusy)

            Text("No API key needed. TubeFold will check the required CLI next.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 540, alignment: .leading)
    }
}

private struct ProviderAccountChoiceView: View {
    let providerID: String
    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                ProviderLogoView(providerID: providerID)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.headline)
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.white)
                        }
                    }
                    Text(subtitle)
                        .font(.subheadline.weight(.semibold))
                }

                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? .white : .primary)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor : Color(nsColor: .controlBackgroundColor)),
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.18), lineWidth: 1),
            )
        }
        .buttonStyle(.plain)
    }
}

private struct ProviderLogoView: View {
    let providerID: String

    var body: some View {
        Image(providerID == "claude" ? "ProviderClaude" : "ProviderOpenAI")
            .resizable()
            .renderingMode(providerID == "claude" ? .original : .template)
            .scaledToFit()
            .padding(providerID == "claude" ? 2 : 4)
            .accessibilityHidden(true)
    }
}

#Preview {
    StepIntroView(viewModel: ProviderSetupViewModel())
        .padding(34)
        .frame(width: 600, height: 480)
}
