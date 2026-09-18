import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    // Under XCTest the bundle is only a test host: no status items, no Accessibility prompt.
    let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    let delegate = isTesting ? nil : AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
