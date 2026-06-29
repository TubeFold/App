import SwiftUI

/// A small bordered action button used in a library row's action cluster
/// (YouTube, Open PDF, Open Telegraph, …). Centralizes the mini-button look so
/// every one of them can be restyled in a single place.
struct RowMiniButton<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Content

    var body: some View {
        Button(action: action, label: label)
            .buttonStyle(.bordered)
            .controlSize(.small)
    }
}

extension RowMiniButton where Content == Label<Text, Image> {
    /// Convenience for the common static title + SF Symbol case.
    init(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) {
        self.action = action
        self.label = { Label(title, systemImage: systemImage) }
    }
}

#Preview {
    HStack(spacing: 8) {
        RowMiniButton("YouTube", systemImage: "play.rectangle") {}

        RowMiniButton {
            // dynamic-label variant
        } label: {
            Label("Open Telegraph", systemImage: "paperplane.fill")
        }

        RowMiniButton("Open PDF", systemImage: "doc.richtext") {}
            .disabled(true)
    }
    .padding()
}
