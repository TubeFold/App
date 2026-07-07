import Foundation

enum SetupStep: Int, CaseIterable, Identifiable {
    case welcome
    case outputLanguage
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
        case .outputLanguage:
            "Output language"
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
