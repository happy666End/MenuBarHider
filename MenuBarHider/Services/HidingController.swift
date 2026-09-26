import AppKit

protocol RunningAppsSource {
    var bundleIDs: [String] { get }
}

protocol TimerScheduler {
    func schedule(after seconds: TimeInterval, _ block: @escaping () -> Void) -> Cancellable
}

protocol Cancellable {
    func cancel()
}

/// Screen x of the two separators; nil when the item is not on screen.
struct SeparatorPositions {
    var separatorX: CGFloat?
    var leftSeparatorX: CGFloat?
}

/// Owns the intent, the hidden set and the timers, and derives the restriction MenuBarAgent holds.
@MainActor
final class HidingController {
    enum State { case shown, hidden }

    /// Time for the freshly created separators to be laid out before the first scan.
    private static let launchSettleDelay: TimeInterval = 1.5
    private static let permissionPollInterval: TimeInterval = 2
    private static let hoverGraceDelay: TimeInterval = 0.5
    /// Time for the revealed items to be laid out before a rescan reads their positions.
    private static let rescanSettleDelay: TimeInterval = 0.6
    /// App launches come in bursts of helper processes; one reconcile per burst is enough.
    private static let runningAppsDebounce: TimeInterval = 1

    private let engine: HidingEngine
    private let items: MenuBarItemSource
    private let runningApps: RunningAppsSource
    private let extras: MenuExtraHost
    private let separators: () -> SeparatorPositions
    private let scheduler: TimerScheduler
    let settings: Settings

    private(set) var state: State = .shown
    private(set) var hiddenSet: Set<String>
    private(set) var lastError: Error?
    /// Notification Center refuses to open while the restriction is active, and an already-open
    /// panel survives its return: the bar stays unrestricted while the pointer rests on the clock.
    var pointerOverClock = false {
        didSet { pointerOverClockChanged(from: oldValue) }
    }

    private var pendingHide: Cancellable?
    private var hoverGrace: Cancellable?
    private var appsChange: Cancellable?
    private var permissionPoll: Cancellable?

    var onChange: (() -> Void)?

    init(
        engine: HidingEngine,
        items: MenuBarItemSource,
        runningApps: RunningAppsSource,
        extras: MenuExtraHost,
        separators: @escaping () -> SeparatorPositions,
        settings: Settings,
        scheduler: TimerScheduler
    ) {
        self.engine = engine
        self.items = items
        self.runningApps = runningApps
        self.extras = extras
        self.separators = separators
        self.settings = settings
        self.scheduler = scheduler
        self.hiddenSet = settings.hiddenBundleIDs
    }

    var isEngineAvailable: Bool { engine.isAvailable }
    var isAccessibilityTrusted: Bool { items.isTrusted }
    var canHide: Bool { engine.isAvailable && items.isTrusted }

    // MARK: - Intent

    func start() {
        reconcileMenuExtras()
        permissionPoll = scheduler.schedule(after: Self.launchSettleDelay) { [weak self] in
            self?.hideWhenPermitted()
        }
    }

    func toggle() {
        switch state {
        case .shown: hide()
        case .hidden: show()
        }
    }

    func show() {
        cancelPendingHide()
        Log.controller.error("show")
        state = .shown
        lastError = nil
        reconcile()
        onChange?()
        armAutoHide()
    }

    func hide() {
        cancelPendingHide()
        guard canHide else {
            Log.controller.error(
                "hide skipped: engine=\(self.engine.isAvailable) accessibility=\(self.items.isTrusted)")
            return
        }
        refreshHiddenSet()
        state = .hidden
        reconcile()
        onChange?()
    }

    /// While collapsed the bar is expanded first and re-collapsed; the collapse performs the scan.
    func rescan() {
        switch state {
        case .shown:
            refreshHiddenSet()
        case .hidden:
            show()
            cancelPendingHide()
            pendingHide = scheduler.schedule(after: Self.rescanSettleDelay) { [weak self] in
                self?.hide()
            }
        }
    }

    func setAutoHideSeconds(_ seconds: Int) {
        settings.autoHideSeconds = seconds
        guard state == .shown else { return }
        cancelPendingHide()
        armAutoHide()
    }

    /// Call on every app launch or quit: the allow list must follow the running set.
    func runningAppsChanged() {
        appsChange?.cancel()
        appsChange = scheduler.schedule(after: Self.runningAppsDebounce) { [weak self] in
            self?.reconcile()
        }
    }

    func shutdown() {
        cancelPendingHide()
        hoverGrace?.cancel()
        appsChange?.cancel()
        permissionPoll?.cancel()
        state = .shown
        engine.release()
        reconcileMenuExtras()
    }

    // MARK: - Derivation

    private var desiredAllowList: [String]? {
        let hiddenApps = hiddenSet.filter { !MenuExtras.isExtra($0) }
        guard state == .hidden, canHide, !pointerOverClock, !hiddenApps.isEmpty else { return nil }
        return HiddenSet.allowList(
            running: runningApps.bundleIDs, hidden: hiddenApps, alwaysAllowed: SystemItems.alwaysAllowedBundleIDs)
    }

    /// No pointerOverClock check: unloaded extras do not block Notification Center.
    private var desiredRemovedExtras: Set<String> {
        guard state == .hidden, canHide else { return [] }
        return hiddenSet.filter(MenuExtras.isExtra)
    }

    /// Idempotent: an unchanged allow list is not re-sent.
    private func reconcile() {
        reconcileMenuExtras()
        guard let desired = desiredAllowList else {
            engine.release()
            return
        }
        guard desired != engine.appliedAllowList else { return }
        engine.restrict(allowedBundleIDs: desired) { [weak self] error in
            guard let self else { return }
            self.lastError = error
            if let error { Log.controller.error("restrict failed: \(error.localizedDescription)") }
            self.onChange?()
        }
    }

    private func reconcileMenuExtras() {
        let desired = desiredRemovedExtras
        var removed = settings.removedMenuExtraIDs
        for id in removed.subtracting(desired).sorted() where extras.restore(id) {
            removed.remove(id)
        }
        for id in desired.subtracting(removed).sorted() where extras.remove(id) {
            removed.insert(id)
        }
        settings.removedMenuExtraIDs = removed
    }

    private func refreshHiddenSet() {
        guard state == .shown, items.isTrusted else { return }
        let positions = separators()
        guard let separatorX = positions.separatorX else { return }
        let scanned = items.scan()
        hiddenSet = HiddenSet.partition(
            items: scanned, leftSeparatorX: positions.leftSeparatorX, separatorX: separatorX)
        settings.hiddenBundleIDs = hiddenSet
        let dump = scanned.map { "\($0.bundleID)@\(Int($0.x))" }
        let leftX = positions.leftSeparatorX.map { "\($0)" } ?? "none"
        Log.controller.error("scan: sep=\(separatorX) left=\(leftX) items=\(dump) hidden=\(self.hiddenSet.sorted())")
    }

    private func pointerOverClockChanged(from previous: Bool) {
        guard previous != pointerOverClock else { return }
        hoverGrace?.cancel()
        if pointerOverClock {
            reconcile()
        } else {
            hoverGrace = scheduler.schedule(after: Self.hoverGraceDelay) { [weak self] in
                self?.reconcile()
            }
        }
    }

    private func hideWhenPermitted() {
        guard state == .shown, isEngineAvailable else { return }
        if isAccessibilityTrusted {
            hide()
        } else {
            Log.controller.error("waiting for Accessibility permission")
            permissionPoll = scheduler.schedule(after: Self.permissionPollInterval) { [weak self] in
                self?.hideWhenPermitted()
            }
        }
    }

    private func armAutoHide() {
        let seconds = settings.autoHideSeconds
        guard seconds > 0 else { return }
        pendingHide = scheduler.schedule(after: TimeInterval(seconds)) { [weak self] in
            self?.hide()
        }
    }

    private func cancelPendingHide() {
        pendingHide?.cancel()
        pendingHide = nil
    }
}

// MARK: - Default implementations

struct DispatchTimerScheduler: TimerScheduler {
    func schedule(after seconds: TimeInterval, _ block: @escaping () -> Void) -> Cancellable {
        let item = DispatchWorkItem(block: block)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return item
    }
}

extension DispatchWorkItem: Cancellable {}

struct WorkspaceRunningApps: RunningAppsSource {
    var bundleIDs: [String] {
        NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
    }
}
