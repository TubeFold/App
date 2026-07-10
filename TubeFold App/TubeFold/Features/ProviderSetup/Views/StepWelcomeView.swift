import AppKit
import SwiftUI

struct StepWelcomeView: View {
    private let introText = "TubeFold turns YouTube videos into saved summaries using your ChatGPT/OpenAI "
        + "or Claude account."

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
                Label("Choose ChatGPT/OpenAI or Claude/Anthropic", systemImage: "person.crop.circle.badge.checkmark")
                Label("TubeFold guides you through the required CLI install", systemImage: "terminal")
                Label("A quick test confirms the CLI is signed in", systemImage: "bolt.fill")
            }
            .font(.headline)
            .foregroundStyle(.primary)
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text("No API key is needed. TubeFold runs the provider's official command-line tool on this Mac.")
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
