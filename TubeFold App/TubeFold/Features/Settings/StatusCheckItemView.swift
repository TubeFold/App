import SwiftUI

struct StatusCheckItemView: View {
    let title: String
    let isReady: Bool
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isReady ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isReady ? .green : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

#Preview {
    HStack(alignment: .top, spacing: 12) {
        StatusCheckItemView(title: "Installed", isReady: true, detail: "v1.2.3")
        StatusCheckItemView(title: "Signed in", isReady: false, detail: "Test required")
    }
    .padding()
    .frame(width: 420)
}
