import Foundation

/// MBSystemItemIdentifier raw values on macOS 27.0 (26A428): 0 battery, 1 bluetooth, 2 clock,
/// 3 displays, 4 keyboard, 5 volume, 6 wifi, 7 screenMirroring, 8 primaryBentoBox.
enum SystemItems {
    /// A generous range so that identifiers added in later builds stay visible too.
    static let allowedIdentifiers: [NSNumber] = (0..<64).map { NSNumber(value: $0) }

    static let menuBarAgentBundleID = "com.apple.MenuBarAgent"

    /// Apple agents whose menu bar extras are addressed by bundle id, not by system item.
    static let alwaysAllowedBundleIDs: Set<String> = [
        "com.apple.controlcenter",
        menuBarAgentBundleID,
        "com.apple.systemuiserver",
        "com.apple.TextInputMenuAgent",
        "com.apple.Siri",
        "com.apple.Spotlight",
        "com.apple.wifi.WiFiAgent",
        "com.apple.ScreenTimeAgent",
        "com.apple.AirPlayUIAgent",
        "com.apple.UserNotificationCenter",
        "com.apple.notificationcenterui",
        "com.apple.loginwindow",
    ]
}
