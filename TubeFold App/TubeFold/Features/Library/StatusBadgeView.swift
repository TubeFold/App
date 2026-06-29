import SwiftUI

struct StatusBadgeView: View {
    let status: String
    @State private var spin = false

    private var isActive: Bool {
        ["queued", "fetchingMetadata", "fetchingTranscript", "generatingSummary"].contains(status)
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
        if isActive {
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
            return "Queued"
        case "fetchingMetadata":
            return "Metadata"
        case "fetchingTranscript":
            return "Transcript"
        case "generatingSummary":
            return "Summarizing"
        case "ready":
            return "Ready"
        case "failed":
            return "Failed"
        case "cancelled":
            return "Cancelled"
        default:
            return status
        }
    }

    private var statusIcon: String {
        switch status {
        case "ready":
            return "checkmark.circle.fill"
        case "failed", "cancelled":
            return "exclamationmark.triangle.fill"
        case "queued":
            return "clock.fill"
        default:
            return "arrow.triangle.2.circlepath"
        }
    }

    private var statusColor: Color {
        switch status {
        case "ready":
            return .green
        case "failed", "cancelled":
            return .orange
        case "queued":
            return .secondary
        default:
            return .blue
        }
    }
}
