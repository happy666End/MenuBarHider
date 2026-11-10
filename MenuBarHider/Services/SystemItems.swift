import Foundation

enum SystemItems {
    struct Control {
        let name: String
        let accessibilityName: String
        let rawValue: Int

        var accessibilityIdentifier: String { "com.apple.menuextra.\(accessibilityName)" }
        var selectionID: String { "system-item:\(name)" }
        var isSelectable: Bool { rawValue != 2 && rawValue != 8 }
    }

    /// MBSystemItemIdentifier and AXIdentifier pairs verified on macOS 27.0.1 (26A434).
    static let controls: [Control] = [
        .init(name: "battery", accessibilityName: "battery", rawValue: 0),
        .init(name: "bluetooth", accessibilityName: "bluetooth", rawValue: 1),
        .init(name: "clock", accessibilityName: "clock", rawValue: 2),
        .init(name: "displays", accessibilityName: "display", rawValue: 3),
        .init(name: "keyboard", accessibilityName: "keyboard-brightness", rawValue: 4),
        .init(name: "volume", accessibilityName: "sound", rawValue: 5),
        .init(name: "wifi", accessibilityName: "wifi", rawValue: 6),
        .init(name: "screenMirroring", accessibilityName: "screen-mirroring", rawValue: 7),
        .init(name: "primaryBentoBox", accessibilityName: "controlcenter", rawValue: 8),
    ]

    static var selectionIDs: Set<String> { Set(controls.filter(\.isSelectable).map(\.selectionID)) }
    static let allowedIdentifiers: [NSNumber] = (0..<256).map { NSNumber(value: $0) }

    static func allowedIdentifiers(hiding identifiers: Set<Int>) -> [NSNumber] {
        let hidden = identifiers.intersection(controls.filter(\.isSelectable).map(\.rawValue))
        return allowedIdentifiers.filter { !hidden.contains($0.intValue) }
    }

    static func selectionID(forAccessibilityIdentifier identifier: String) -> String? {
        controls.first { $0.accessibilityIdentifier == identifier && $0.isSelectable }?.selectionID
    }

    static func hiddenIdentifiers(in selections: Set<String>) -> Set<Int> {
        Set(controls.filter { $0.isSelectable && selections.contains($0.selectionID) }.map(\.rawValue))
    }

    static func isSystemSelection(_ identifier: String) -> Bool { identifier.hasPrefix("system-item:") }

    static let menuBarAgentBundleID = "com.apple.MenuBarAgent"
    static let systemUIServerBundleID = "com.apple.systemuiserver"

    /// Shared hosts are scanned by their item identifiers rather than as one application.
    static let alwaysAllowedBundleIDs: Set<String> = [
        "com.apple.controlcenter", menuBarAgentBundleID, systemUIServerBundleID,
    ]
}
