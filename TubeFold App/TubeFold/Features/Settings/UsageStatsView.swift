import SwiftUI

struct UsageStatsView: View {
    @ObservedObject var viewModel: ProviderSetupViewModel

    private var usage: UsageSummary {
        viewModel.usage ?? .empty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Usage")
                        .font(.headline)
                    Text("Tokens TubeFold has spent analyzing videos with your provider CLI.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Button {
                    Task { await viewModel.refreshUsage() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh usage")
            }

            if usage.totalTokens == 0 {
                Text("No analyses recorded yet. Token usage appears here after your first summary.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(UsageStatsView.formatTokens(usage.totalTokens))
                        .font(.system(.title, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                    Text("tokens total")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                ForEach(usage.sortedProviders, id: \.name) { entry in
                    providerRow(name: entry.name, usage: entry.usage)
                }
            }
        }
        .settingsCard()
    }

    private func providerRow(name: String, usage: UsageSummary.ProviderUsage) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(UsageStatsView.providerDisplayName(name))
                .font(.subheadline.weight(.semibold))
            Text("\(usage.jobs) runs")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text("\(UsageStatsView.formatTokens(usage.totalTokens)) tokens")
                .font(.callout)
                .monospacedDigit()
        }
    }

    static func providerDisplayName(_ id: String) -> String {
        switch id {
        case "codex": "Codex CLI"
        case "claude": "Claude Code CLI"
        default: id.capitalized
        }
    }

    static func formatTokens(_ tokens: Int) -> String {
        let value = Double(tokens)
        if value >= 1_000_000 {
            return String(format: "%.1fM", value / 1_000_000)
        }
        if value >= 1000 {
            return String(format: "%.1fK", value / 1000)
        }
        return String(tokens)
    }
}

#Preview {
    UsageStatsView(viewModel: ProviderSetupViewModel())
        .padding()
        .frame(width: 560)
}
