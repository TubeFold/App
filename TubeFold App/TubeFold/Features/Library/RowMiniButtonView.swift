import SwiftUI

/// A small bordered action button used in a library row's action cluster
/// (YouTube, Open PDF, Open Telegraph, …).
struct RowMiniButtonView<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Content

    var body: some View {
        Button(action: action) {
            label()
                .padding(.vertical, RowMiniControl.labelVerticalPadding)
        }
        .rowMiniControlStyle()
    }
}

extension RowMiniButtonView where Content == Label<Text, Image> {
    /// Convenience for the common static title + SF Symbol case.
    init(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) {
        self.action = action
        self.label = { Label(title, systemImage: systemImage) }
    }
}

#Preview {
    HStack(spacing: 8) {
        RowMiniButtonView("YouTube", systemImage: "play.rectangle") {}

        RowMiniButtonView {
            // dynamic-label variant
        } label: {
            Label("Open Telegraph", systemImage: "paperplane.fill")
        }

        RowMiniButtonView("Open PDF", systemImage: "doc.richtext") {}
            .disabled(true)

        RowMiniMenuView("More", systemImage: "ellipsis") {
            Button("Show Files") {}
            Button("Delete", role: .destructive) {}
        }
    }
    .padding()
}
