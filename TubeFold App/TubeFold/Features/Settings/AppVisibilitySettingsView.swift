import SwiftUI

struct AppVisibilitySettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("App visibility")
                    .font(.headline)
                Text("Show TubeFold in the Dock, in the menu bar, or both. The main window stays available.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker("App visibility", selection: $settings.appVisibilityMode) {
                ForEach(AppVisibilityMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
        .settingsCard()
    }
}

#Preview {
    AppVisibilitySettingsView()
        .padding()
        .frame(width: 560)
}
