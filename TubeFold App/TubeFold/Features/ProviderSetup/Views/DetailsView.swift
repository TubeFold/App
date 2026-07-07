import AppKit
import SwiftUI

struct DetailsView: View {
    let details: [String]
    let showsCopyButton: Bool
    @State private var copied = false

    var body: some View {
        if !details.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(details, id: \.self) { line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                HStack(spacing: 10) {
                    Text("Details")

                    if showsCopyButton {
                        Button {
                            copyLogs()
                        } label: {
                            Label(copied ? "Copied" : "Copy all logs", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help("Copy all diagnostic logs")
                        .accessibilityLabel("Copy all diagnostic logs")
                        .disabled(details.isEmpty)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func copyLogs() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(details.joined(separator: "\n"), forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

#Preview {
    DetailsView(details: [
        "$ codex --version",
        "codex 0.142.0",
        "exit code: 0",
    ], showsCopyButton: true)
        .padding()
        .frame(width: 560)
}
