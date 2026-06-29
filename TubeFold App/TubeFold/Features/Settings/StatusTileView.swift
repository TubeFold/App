import SwiftUI

struct StatusTileView: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color
    /// When set, the tile becomes clickable and runs this on tap.
    var action: (() -> Void)?

    @State private var isHovering = false

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(value)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    var body: some View {
        if let action {
            Button(action: action) {
                content
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(tint.opacity(isHovering ? 0.6 : 0), lineWidth: 1),
                    )
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .help("Open in Finder")
        } else {
            content
        }
    }
}

#Preview {
    HStack(spacing: 12) {
        StatusTileView(title: "App", value: "Ready", systemImage: "macwindow", tint: .indigo)
        StatusTileView(title: "Codex CLI", value: "gpt-5 · high", systemImage: "terminal", tint: .blue)
        StatusTileView(title: "Extension", value: "Connected", systemImage: "puzzlepiece.extension", tint: .pink)
    }
    .padding()
    .frame(width: 520, height: 140)
}
