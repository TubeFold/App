import SwiftUI

struct StatusCheckItemView: View {
    let title: String
    let isReady: Bool
    let detail: String
    var isWarning = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isWarning ? Color.orange : Color.primary)
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

    private var statusIcon: String {
        if isWarning {
            return "exclamationmark.triangle.fill"
        }
        return isReady ? "checkmark.circle.fill" : "circle"
    }

    private var statusColor: Color {
        if isWarning {
            return .orange
        }
        return isReady ? .green : .secondary
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
