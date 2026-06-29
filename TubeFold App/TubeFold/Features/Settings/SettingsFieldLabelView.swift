import SwiftUI

/// Small uppercase caption used to label a form control.
struct SettingsFieldLabelView: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.5)
            .foregroundStyle(.secondary)
    }
}
