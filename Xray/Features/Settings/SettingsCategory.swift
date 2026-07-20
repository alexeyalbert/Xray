import Foundation

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case ai
    case browserImport
    case debug

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:
            return "General"
        case .ai:
            return "Models"
        case .browserImport:
            return "Browser Import"
        case .debug:
            return "Debug"
        }
    }

    var subtitle: String {
        switch self {
        case .general:
            return "Overview and app behavior"
        case .ai:
            return "Providers, keys, and models"
        case .browserImport:
            return "Receiver and local browser bridge"
        case .debug:
            return "Diagnostics and database maintenance"
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            return "gearshape"
        case .ai:
            return "tag"
        case .browserImport:
            return "dot.radiowaves.left.and.right"
        case .debug:
            return "ladybug"
        }
    }
}
