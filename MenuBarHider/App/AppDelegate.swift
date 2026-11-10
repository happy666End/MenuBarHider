import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController!
    private var controller: HidingController!
    private var hoverMonitor: ClockHoverMonitor!
    private var runningAppsObservation: NSKeyValueObservation?
    private var nativeAccess: NativePreferencesAccess!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let isInApplications = AppLocation.isInApplications(Bundle.main.bundleURL)
        if isInApplications {
            MenuBarScanner.requestTrust()
        } else if ApplicationsMover.offerMove() {
            return
        }

        statusItem = StatusItemController()
        nativeAccess = NativePreferencesAccess()
        let extras = SystemUIServerExtras()
        let running = WorkspaceRunningApps()
        let engine = HidingEngineRouter(
            settings: Settings.shared, assessment: MenuBarAgentBridge(),
            native: NativeHidingEngine(
                store: SystemTrackedApplicationsStore(), journal: FileNativeVisibilityJournal(), runningApps: running))
        controller = HidingController(
            engine: engine,
            items: MenuBarScanner(extras: extras),
            runningApps: running,
            extras: extras,
            separators: { [weak statusItem] in statusItem?.separators ?? SeparatorPositions() },
            isInApplications: isInApplications,
            settings: Settings.shared,
            scheduler: DispatchTimerScheduler()
        )
        statusItem.attach(controller, nativeAccess: nativeAccess)

        // Relevant while already over the clock too: an auto-hide can fire under a resting pointer.
        hoverMonitor = ClockHoverMonitor { [weak controller] in
            guard let controller else { return false }
            return controller.requiresClockHover && (controller.state == .hidden || controller.pointerOverClock)
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller, !controller.shutdown() else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Some Menu Bar Items Could Not Be Restored"
        alert.informativeText =
            "\(controller.lastError?.localizedDescription ?? "Restoration failed.")\n\n"
            + "Keep MenuBarHider running to retry. If you quit, recovery will be retried on the next launch."
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}
