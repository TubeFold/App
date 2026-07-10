import SwiftUI

struct StepRowView: View {
    let step: SetupStep
    let isCurrent: Bool
    let isComplete: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isComplete ? .green : (isCurrent ? Color.accentColor : .secondary))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 22)
            Text(step.title)
                .font(.headline)
                .foregroundStyle(isCurrent ? .primary : .secondary)
            Spacer()
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        // Accent, not orange: the highlight marks "you are here", and orange
        // reads as a warning everywhere else in the app.
        .background(
            isCurrent ? Color.accentColor.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous),
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isCurrent ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1),
        )
        .animation(.smooth(duration: 0.3), value: isCurrent)
        .animation(.smooth(duration: 0.3), value: isComplete)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 14) {
        StepRowView(step: .welcome, isCurrent: false, isComplete: true)
        StepRowView(step: .beforeBegin, isCurrent: false, isComplete: true)
        StepRowView(step: .checkInstallation, isCurrent: true, isComplete: false)
        StepRowView(step: .testConnection, isCurrent: false, isComplete: false)
    }
    .padding()
    .frame(width: 235)
}
