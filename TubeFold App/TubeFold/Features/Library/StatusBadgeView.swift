import SwiftUI

struct StatusBadgeView: View {
    let status: String

    private var isSpinning: Bool {
        ["fetchingMetadata", "fetchingTranscript", "generatingSummary"].contains(status)
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: statusIcon)
                .symbolEffect(.rotate, options: .repeat(.continuous), isActive: isSpinning)
                .contentTransition(.symbolEffect(.replace))
            Text(statusTitle)
                .contentTransition(.interpolate)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(statusColor)
        .padding(.vertical, 5)
        .padding(.horizontal, 9)
        .background(statusColor.opacity(0.12), in: Capsule())
        // Status flips arrive from background polling; animate the swap so the
        // badge morphs between stages instead of hard-cutting.
        .animation(.smooth(duration: 0.3), value: status)
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
        case "failed":
            "exclamationmark.triangle.fill"
        case "cancelled":
            "slash.circle.fill"
        case "queued":
            "clock.fill"
        default:
            "arrow.triangle.2.circlepath"
        }
    }

    /// Red = error, secondary = neutral end state; orange stays reserved for
    /// warnings elsewhere so each color keeps one meaning across the app.
    private var statusColor: Color {
        switch status {
        case "ready":
            .green
        case "failed":
            .red
        case "cancelled", "queued":
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
