import AppKit
import SwiftUI

struct StepWelcomeView: View {
    private let introText = "TubeFold turns YouTube videos into saved summaries using a signed-in "
        + "command-line provider on this Mac."

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            logoImage
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 12) {
                Text("Hi, welcome to TubeFold")
                    .font(.largeTitle.weight(.semibold))

                Text(introText)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 14) {
                Label("Choose the summary output language", systemImage: "textformat")
                Label("Choose Codex CLI or Claude Code CLI", systemImage: "terminal")
                Label("TubeFold checks that the provider is installed", systemImage: "checkmark.shield")
                Label("A quick test confirms the provider is signed in", systemImage: "bolt.fill")
            }
            .font(.headline)
            .foregroundStyle(.primary)
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))

            Text("You will use your own provider subscription. No API key is needed.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    @ViewBuilder
    private var logoImage: some View {
        if let image = Self.logoImage {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.blue)
        }
    }

    private static var logoImage: NSImage? {
        NSApplication.shared.applicationIconImage
    }
}

#Preview {
    StepWelcomeView()
        .padding(34)
        .frame(width: 620, height: 520)
}
