import Foundation

enum MenuExtras {
    static func isExtra(_ id: String) -> Bool {
        id.hasPrefix("com.apple.menuextra.")
    }

    /// Handles are load counters: 0 is unloaded, negative left SystemUIServer (Wi-Fi -8).
    static func loadOrder(handles: [String: Int32]) -> [String] {
        handles.filter { $0.value > 0 }.sorted { $0.value < $1.value }.map(\.key)
    }

    static func positions(itemXs: [CGFloat], loadedIDs: [String]) -> [MenuBarItemPosition] {
        zip(loadedIDs, itemXs).map { MenuBarItemPosition(bundleID: $0, x: $1) }
    }
}
