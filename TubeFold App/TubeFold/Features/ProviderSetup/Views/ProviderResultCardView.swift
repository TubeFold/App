import SwiftUI

struct ProviderResultCardView: View {
    let title: String
    let status: String
    let message: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                Text(status)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

#Preview {
    ProviderResultCardView(
        title: "Codex CLI",
        status: "Installed",
        message: "Found codex 0.142.0 at /opt/homebrew/bin/codex.",
        systemImage: "checkmark.circle.fill",
        tint: .green
    )
    .padding()
    .frame(width: 560)
}
