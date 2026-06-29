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
