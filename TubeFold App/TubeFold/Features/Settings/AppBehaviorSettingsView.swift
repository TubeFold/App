import SwiftUI

struct AppBehaviorSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("App behavior")
                    .font(.headline)
                Text("Control how TubeFold reacts when a summary finishes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle(isOn: $settings.autoOpenTelegraph) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open Telegraph automatically")
                    Text("When a summary is ready, publish it to Telegraph and open the page in your browser.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Toggle(isOn: $settings.hideMenuBarIcon) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hide menu bar icon")
                    Text("Remove the TubeFold icon from the macOS menu bar. The main window stays available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .settingsCard()
    }
}
