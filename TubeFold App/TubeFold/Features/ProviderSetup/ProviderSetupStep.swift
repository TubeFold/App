import Foundation

enum SetupStep: Int, CaseIterable, Identifiable {
    case welcome
    case beforeBegin
    case checkInstallation
    case testConnection
    case complete

    var id: Int {
        rawValue
    }

    var title: String {
        switch self {
        case .welcome:
            "Welcome"
        case .beforeBegin:
            "Choose provider"
        case .checkInstallation:
            "Check installation"
        case .testConnection:
            "Test connection"
        case .complete:
            "Complete"
        }
    }
}
