import Foundation

final class Settings {
    static let shared = Settings()

    private let defaults: UserDefaults
    private enum Key {
        static let autoHideSeconds = "autoHideSeconds"
        static let hiddenBundleIDs = "hiddenBundleIDs"
        static let removedMenuExtraIDs = "removedMenuExtraIDs"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Key.autoHideSeconds: 10])
    }

    /// 0 disables the auto-hide timer.
    var autoHideSeconds: Int {
        get { defaults.integer(forKey: Key.autoHideSeconds) }
        set { defaults.set(newValue, forKey: Key.autoHideSeconds) }
    }

    /// Last computed hidden set: lets the app hide before the first Accessibility scan.
    var hiddenBundleIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.hiddenBundleIDs) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: Key.hiddenBundleIDs) }
    }

    var removedMenuExtraIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.removedMenuExtraIDs) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: Key.removedMenuExtraIDs) }
    }
}
