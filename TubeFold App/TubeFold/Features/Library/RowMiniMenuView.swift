import SwiftUI

/// A small bordered menu that matches `RowMiniButtonView` — used for the row's
/// "More" menu so it lines up with the other mini buttons.
struct RowMiniMenuView<MenuItems: View, Content: View>: View {
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

extension RowMiniMenuView where Content == Label<Text, Image> {
    /// Convenience for the common static title + SF Symbol case.
    init(_ title: LocalizedStringKey, systemImage: String, @ViewBuilder content: @escaping () -> MenuItems) {
        self.content = content
        self.label = { Label(title, systemImage: systemImage) }
    }
}
