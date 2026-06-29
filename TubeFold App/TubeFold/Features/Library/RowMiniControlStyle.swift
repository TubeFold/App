import SwiftUI

/// Shared look for a library row's mini controls (`RowMiniButtonView` / `RowMiniMenuView`),
/// kept in one place so the whole action cluster can be restyled together.
enum RowMiniControl {
    /// Extra top/bottom breathing room inside the bordered pill.
    static let labelVerticalPadding: CGFloat = 0
    /// Gap between the SF Symbol and the title. Pinned here so a Button and a
    /// Menu (whose default label spacing is wider) render identically.
    static let labelSpacing: CGFloat = 4
}

/// Forces the same icon↔title gap on every mini control. A `Menu`'s default
/// label spacing is wider than a `Button`'s, which made "More" look off next to
/// the other buttons — this makes them match by construction.
struct RowMiniLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: RowMiniControl.labelSpacing) {
            configuration.icon
            configuration.title
        }
    }
}

extension View {
    func rowMiniControlStyle() -> some View {
        labelStyle(RowMiniLabelStyle())
            .buttonStyle(.bordered)
            .controlSize(.small)
    }
}
