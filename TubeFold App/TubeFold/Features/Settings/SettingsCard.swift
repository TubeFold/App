import SwiftUI

extension View {
    /// Consistent card chrome for every Settings section.
    func settingsCard() -> some View {
        padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                // Hairline edge so the material card keeps definition on
                // backgrounds it barely differs from (especially light mode).
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1),
            )
    }
}
