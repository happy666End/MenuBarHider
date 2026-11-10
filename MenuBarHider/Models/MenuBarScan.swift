import Foundation

struct MenuBarScan {
    var positions: [MenuBarItemPosition]
    var failedBundleIDs: Set<String>

    init(positions: [MenuBarItemPosition], failedBundleIDs: Set<String> = []) {
        self.positions = positions
        self.failedBundleIDs = failedBundleIDs
    }
}
