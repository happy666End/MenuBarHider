import Foundation

enum HidingMethod: String, CaseIterable {
    case assessment
    case systemSettings

    var title: String {
        switch self {
        case .assessment: return "Compatibility"
        case .systemSettings: return "System Settings (Experimental)"
        }
    }
}
