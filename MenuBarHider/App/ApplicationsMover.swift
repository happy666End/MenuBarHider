import AppKit

@MainActor
enum ApplicationsMover {
    /// True when the app relaunches from /Applications and this launch must stop.
    static func offerMove() -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Move MenuBarHider to Applications?"
        alert.informativeText = """
            macOS keeps the icons of apps run from outside the Applications folder hidden, \
            MenuBarHider's own » included. Hiding stays off until the app is moved.
            """
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        return move()
    }

    @discardableResult
    static func move() -> Bool {
        let installed: URL
        do {
            installed = try AppLocation.install(Bundle.main.bundleURL, into: AppLocation.applicationsFolder)
        } catch {
            Log.ui.error("move to Applications failed: \(error.localizedDescription)")
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "Could not move MenuBarHider"
            alert.informativeText = "\(error.localizedDescription)\n\nDrag MenuBarHider into Applications in Finder."
            alert.runModal()
            return false
        }
        relaunch(from: installed)
        return true
    }

    private static func relaunch(from url: URL) {
        // Another running copy would keep its separators and its restriction alive.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        where app.processIdentifier != ownPID {
            app.terminate()
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    Log.ui.error("relaunch from Applications failed: \(error.localizedDescription)")
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                NSApp.terminate(nil)
            }
        }
    }
}
