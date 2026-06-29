import SwiftUI

/// Shared look for a library row's mini controls (`RowMiniButton` / `RowMiniMenu`),
/// kept in one place so the whole action cluster can be restyled together.
private enum RowMiniControl {
    /// Extra top/bottom breathing room inside the bordered pill.
    static let labelVerticalPadding: CGFloat = 0
    /// Gap between the SF Symbol and the title. Pinned here so a Button and a
    /// Menu (whose default label spacing is wider) render identically.
    static let labelSpacing: CGFloat = 4
}

/// Forces the same icon↔title gap on every mini control. A `Menu`'s default
/// label spacing is wider than a `Button`'s, which made "More" look off next to
/// the other buttons — this makes them match by construction.
private struct RowMiniLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: RowMiniControl.labelSpacing) {
            configuration.icon
            configuration.title
        }
    }
}

private extension View {
    func rowMiniControlStyle() -> some View {
        self
            .labelStyle(RowMiniLabelStyle())
            .buttonStyle(.bordered)
            .controlSize(.small)
    }
}

/// A small bordered action button used in a library row's action cluster
/// (YouTube, Open PDF, Open Telegraph, …).
struct RowMiniButton<Content: View>: View {
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

extension RowMiniButton where Content == Label<Text, Image> {
    /// Convenience for the common static title + SF Symbol case.
    init(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) {
        self.action = action
        self.label = { Label(title, systemImage: systemImage) }
    }
}

/// A small bordered menu that matches `RowMiniButton` — used for the row's
/// "More" menu so it lines up with the other mini buttons.
struct RowMiniMenu<MenuItems: View, Content: View>: View {
    @ViewBuilder let content: () -> MenuItems
    @ViewBuilder let label: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            label()
                .padding(.vertical, RowMiniControl.labelVerticalPadding)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .rowMiniControlStyle()
    }
}

extension RowMiniMenu where Content == Label<Text, Image> {
    /// Convenience for the common static title + SF Symbol case.
    init(_ title: LocalizedStringKey, systemImage: String, @ViewBuilder content: @escaping () -> MenuItems) {
        self.content = content
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

        RowMiniMenu("More", systemImage: "ellipsis") {
            Button("Show Files") {}
            Button("Delete", role: .destructive) {}
        }
    }
    .padding()
}
