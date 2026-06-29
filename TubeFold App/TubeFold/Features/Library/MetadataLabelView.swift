import SwiftUI

struct MetadataLabelView: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

#Preview {
    HStack(spacing: 14) {
        MetadataLabelView(systemImage: "clock", text: "12 min watch")
        MetadataLabelView(systemImage: "book", text: "4 min read")
        MetadataLabelView(systemImage: "calendar", text: "Jun 29, 2026")
    }
    .padding()
}
