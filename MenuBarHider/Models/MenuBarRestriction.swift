import Foundation

struct MenuBarRestriction: Equatable {
    var allowedBundleIDs: [String]
    var hiddenSystemItems: Set<Int> = []
}

enum HidingRestrictionFailure: LocalizedError {
    case unsupportedAppleItems

    var errorDescription: String? {
        "System Settings cannot hide the selected Apple menu items. Choose Compatibility for this layout."
    }
}
