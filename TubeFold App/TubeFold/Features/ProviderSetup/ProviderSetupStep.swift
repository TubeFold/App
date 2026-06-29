import Foundation

enum SetupStep: Int, CaseIterable, Identifiable {
    case beforeBegin
    case checkInstallation
    case testConnection
    case complete

    var id: Int {
        rawValue
    }

    var title: String {
        switch self {
        case .beforeBegin:
            "Before you begin"
        case .checkInstallation:
            "Check installation"
        case .testConnection:
            "Test connection"
        case .complete:
            "Complete"
        }
    }
}
