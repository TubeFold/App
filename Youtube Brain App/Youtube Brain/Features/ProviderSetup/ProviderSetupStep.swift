import Foundation

enum SetupStep: Int, CaseIterable, Identifiable {
    case beforeBegin
    case checkInstallation
    case testConnection
    case complete

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .beforeBegin:
            return "Before you begin"
        case .checkInstallation:
            return "Check installation"
        case .testConnection:
            return "Test connection"
        case .complete:
            return "Complete"
        }
    }
}
