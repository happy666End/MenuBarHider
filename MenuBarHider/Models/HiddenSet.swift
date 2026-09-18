import Foundation

struct MenuBarItemPosition: Equatable {
    let bundleID: String
    let x: CGFloat
}

/// Pure logic for the separator layout `[visible] | [hidden] » [visible]`.
enum HiddenSet {
    /// A nil `leftSeparatorX` means the `|` is off screen: everything left of `»` is hidden.
    static func partition(items: [MenuBarItemPosition], leftSeparatorX: CGFloat?, separatorX: CGFloat) -> Set<String> {
        Set(
            items.filter { item in
                guard item.x < separatorX else { return false }
                if let leftX = leftSeparatorX, item.x < leftX { return false }
                return true
            }.map(\.bundleID))
    }

    static func allowList(running: [String], hidden: Set<String>, alwaysAllowed: Set<String>) -> [String] {
        Array(Set(running).subtracting(hidden).union(alwaysAllowed)).sorted()
    }
}
