import SwiftUI

struct StepRowView: View {
    let step: SetupStep
    let isCurrent: Bool
    let isComplete: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isComplete ? .green : (isCurrent ? .orange : .secondary))
                .frame(width: 22)
            Text(step.title)
                .font(.headline)
                .foregroundStyle(isCurrent ? .primary : .secondary)
            Spacer()
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(isCurrent ? Color.orange.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isCurrent ? Color.orange.opacity(0.65) : Color.clear, lineWidth: 1),
        )
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
