import AppKit

MainActor.assumeIsolated {
    guard !ApplicationRelaunch.runHelperIfRequested() else { return }
    // Under XCTest the bundle is only a test host: no status items, no Accessibility prompt.
    let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    let instanceLock: ApplicationInstanceLock?
    if isTesting {
        instanceLock = nil
    } else {
        do {
            guard let acquiredLock = try ApplicationInstanceLock.acquire() else { return }
            instanceLock = acquiredLock
        } catch {
            Log.ui.error(
                "Unable to acquire the application instance lock: \(error.localizedDescription, privacy: .public)")
            NSAlert(error: error).runModal()
            return
        }
    }
    let app = NSApplication.shared
    let delegate = isTesting ? nil : AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime((instanceLock, delegate)) {
        app.run()
    }
}
