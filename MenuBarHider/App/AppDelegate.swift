import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController!
    private var controller: HidingController!
    private var hoverMonitor: ClockHoverMonitor!
    private var runningAppsObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let isInApplications = AppLocation.isInApplications(Bundle.main.bundleURL)
        if isInApplications {
            MenuBarScanner.requestTrust()
        } else if ApplicationsMover.offerMove() {
            return
        }

        statusItem = StatusItemController()
        let extras = SystemUIServerExtras()
        controller = HidingController(
            engine: MenuBarAgentBridge(),
            items: MenuBarScanner(extras: extras),
            runningApps: WorkspaceRunningApps(),
            extras: extras,
            separators: { [weak statusItem] in statusItem?.separators ?? SeparatorPositions() },
            isInApplications: isInApplications,
            settings: Settings.shared,
            scheduler: DispatchTimerScheduler()
        )
        statusItem.attach(controller)

        // Relevant while already over the clock too: an auto-hide can fire under a resting pointer.
        hoverMonitor = ClockHoverMonitor { [weak controller] in
            guard let controller else { return false }
            return controller.state == .hidden || controller.pointerOverClock
        }
        hoverMonitor.onChange = { [weak controller] over in controller?.pointerOverClock = over }
        controller.onChange = { [weak self] in
            self?.statusItem.stateChanged()
            self?.hoverMonitor.update()
        }
        hoverMonitor.start()

        // didLaunchApplicationNotification skips LSUIElement apps; this KVO fires on main.
        runningAppsObservation = NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.controller.runningAppsChanged() }
        }

        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
    }
}
