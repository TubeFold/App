import SwiftUI

struct StatusBadgeView: View {
    let status: String
    @State private var spin = false

    private var isSpinning: Bool {
        ["fetchingMetadata", "fetchingTranscript", "generatingSummary"].contains(status)
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: statusIcon)
                .rotationEffect(.degrees(spin ? 360 : 0))
            Text(statusTitle)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(statusColor)
        .padding(.vertical, 5)
        .padding(.horizontal, 9)
        .background(statusColor.opacity(0.12), in: Capsule())
        .onAppear { updateSpin() }
        .onChange(of: status) { _, _ in updateSpin() }
    }

    private func updateSpin() {
        if isSpinning {
            spin = false
            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                spin = true
            }
        } else {
            withAnimation(.default) { spin = false }
        }
    }

    private var statusTitle: String {
        switch status {
        case "queued":
            "Queued"
        case "fetchingMetadata":
            "Metadata"
        case "fetchingTranscript":
            "Transcript"
        case "generatingSummary":
            "Summarizing"
        case "ready":
            "Ready"
        case "failed":
            "Failed"
        case "cancelled":
            "Cancelled"
        default:
            status
        }
    }

    private var statusIcon: String {
        switch status {
        case "ready":
            "checkmark.circle.fill"
        case "failed", "cancelled":
            "exclamationmark.triangle.fill"
        case "queued":
            "clock.fill"
        default:
            "arrow.triangle.2.circlepath"
        }
    }

    private var statusColor: Color {
        switch status {
        case "ready":
            .green
        case "failed", "cancelled":
            .orange
        case "queued":
            .secondary
        default:
            .blue
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 8) {
        StatusBadgeView(status: "queued")
        StatusBadgeView(status: "generatingSummary")
        StatusBadgeView(status: "ready")
        StatusBadgeView(status: "failed")
    }
    .padding()
}
