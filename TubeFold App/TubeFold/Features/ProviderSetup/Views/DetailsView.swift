import SwiftUI

struct DetailsView: View {
    let details: [String]

    var body: some View {
        if !details.isEmpty {
            DisclosureGroup("Details") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(details, id: \.self) { line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 8)
            }
        }
    }
}

#Preview {
    DetailsView(details: [
        "$ codex --version",
        "codex 0.142.0",
        "exit code: 0",
    ])
    .padding()
    .frame(width: 560)
}
