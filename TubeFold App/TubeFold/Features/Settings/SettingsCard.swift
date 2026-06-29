import SwiftUI

extension View {
    /// Consistent card chrome for every Settings section.
    func settingsCard() -> some View {
        padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
