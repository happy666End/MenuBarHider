import XCTest

@testable import MenuBarHider

@MainActor
final class HidingControllerTests: XCTestCase {
    private var engine: FakeEngine!
    private var items: FakeItems!
    private var running: FakeRunning!
    private var extras: FakeExtras!
    private var scheduler: ManualScheduler!
    private var settings: Settings!
    private var suiteName: String!
    private var leftSeparatorX: CGFloat?
    private var controller: HidingController!

    override func setUp() {
        super.setUp()
        engine = FakeEngine()
        items = FakeItems()
        running = FakeRunning()
        extras = FakeExtras()
        scheduler = ManualScheduler()
        suiteName = "HidingControllerTests-\(UUID().uuidString)"
        settings = Settings(defaults: UserDefaults(suiteName: suiteName)!)
        controller = makeController()
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeController() -> HidingController {
        HidingController(
            engine: engine, items: items, runningApps: running, extras: extras,
            separators: { [unowned self] in SeparatorPositions(separatorX: 500, leftSeparatorX: self.leftSeparatorX) },
            settings: settings, scheduler: scheduler)
    }

    private func hideOneApp() {
        items.positions = [.init(bundleID: "left", x: 100)]
        controller.hide()
    }

    // MARK: - Hiding

    func testHideScansPartitionsAndRestricts() {
        items.positions = [.init(bundleID: "left", x: 100), .init(bundleID: "right", x: 900)]
        running.bundleIDs = ["left", "right", "other"]

        controller.hide()

        XCTAssertEqual(controller.state, .hidden)
        XCTAssertEqual(controller.hiddenSet, ["left"])
        XCTAssertEqual(engine.restrictions.count, 1)
        let allowed = Set(engine.restrictions[0])
        XCTAssertTrue(allowed.isSuperset(of: ["right", "other", "com.apple.controlcenter"]))
        XCTAssertFalse(allowed.contains("left"))
        XCTAssertEqual(settings.hiddenBundleIDs, ["left"])
    }

    func testItemsLeftOfLeftSeparatorStayVisible() {
        leftSeparatorX = 200
        items.positions = [
            .init(bundleID: "pinned", x: 100), .init(bundleID: "middle", x: 300), .init(bundleID: "right", x: 900),
        ]
        running.bundleIDs = ["pinned", "middle", "right"]

        controller.hide()

        XCTAssertEqual(controller.hiddenSet, ["middle"])
        XCTAssertTrue(engine.restrictions[0].contains("pinned"))
        XCTAssertFalse(engine.restrictions[0].contains("middle"))
    }

    func testEmptyHiddenSetHoldsNoRestriction() {
        items.positions = [.init(bundleID: "right", x: 900)]
        controller.hide()
        XCTAssertEqual(controller.state, .hidden)
        XCTAssertTrue(engine.restrictions.isEmpty, "nothing to hide, so assessment mode must stay off")
    }

    func testHideDoesNothingWithoutAccessibility() {
        items.isTrusted = false
        hideOneApp()
        XCTAssertEqual(controller.state, .shown)
        XCTAssertTrue(engine.restrictions.isEmpty)
    }

    func testHiddenSetPersistsAcrossInstances() {
        hideOneApp()
        XCTAssertEqual(makeController().hiddenSet, ["left"])
    }

    func testActivationErrorIsExposedAndClearedByShow() {
        engine.nextError = Boom()
        hideOneApp()
        XCTAssertNotNil(controller.lastError)
        XCTAssertEqual(controller.state, .hidden, "the intent stands; the menu shows the error")

        engine.nextError = nil
        controller.show()
        XCTAssertNil(controller.lastError)
    }

    // MARK: - Showing and timers

    func testShowReleasesAndArmsTimerThatHidesAgain() {
        settings.autoHideSeconds = 7
        hideOneApp()

        controller.show()
        XCTAssertEqual(controller.state, .shown)
        XCTAssertEqual(engine.releases, 1)
        XCTAssertEqual(scheduler.live.count, 1)
        XCTAssertEqual(scheduler.live[0].seconds, 7)

        scheduler.fireAll()
        XCTAssertEqual(controller.state, .hidden)
        XCTAssertEqual(engine.restrictions.count, 2)
    }

    func testAutoHideDisabledDoesNotArmTimer() {
        settings.autoHideSeconds = 0
        hideOneApp()
        controller.show()
        XCTAssertTrue(scheduler.live.isEmpty)
    }

    func testToggleCancelsPendingTimer() {
        settings.autoHideSeconds = 5
        hideOneApp()
        controller.show()
        controller.toggle()
        XCTAssertEqual(controller.state, .hidden)
        scheduler.fireAll()
        XCTAssertEqual(engine.restrictions.count, 2, "cancelled timer must not restrict a third time")
    }

    func testChangingAutoHideWhileShownReArmsTimer() {
        settings.autoHideSeconds = 10
        hideOneApp()
        controller.show()
        XCTAssertEqual(scheduler.live.count, 1)

        controller.setAutoHideSeconds(0)
        XCTAssertTrue(scheduler.live.isEmpty, "Never must cancel the armed timer")

        controller.setAutoHideSeconds(5)
        XCTAssertEqual(scheduler.live.map(\.seconds), [5])
    }

    func testRescanWhileHiddenExpandsThenCollapsesAgain() {
        settings.autoHideSeconds = 0
        hideOneApp()

        controller.rescan()
        XCTAssertEqual(controller.state, .shown)
        items.positions = [.init(bundleID: "left", x: 100), .init(bundleID: "moved", x: 200)]
        scheduler.fireAll()
        XCTAssertEqual(controller.state, .hidden)
        XCTAssertEqual(controller.hiddenSet, ["left", "moved"], "the settle delay must end in a fresh scan")
    }

    func testStartWaitsForAccessibilityThenHides() {
        items.isTrusted = false
        items.positions = [.init(bundleID: "left", x: 100)]
        controller.start()
        scheduler.fireAll()
        XCTAssertEqual(controller.state, .shown)
        scheduler.fireAll()
        XCTAssertEqual(scheduler.live.count, 1, "keeps polling")

        items.isTrusted = true
        scheduler.fireAll()
        XCTAssertEqual(controller.state, .hidden)
        XCTAssertEqual(engine.restrictions.count, 1)
    }

    // MARK: - Running apps

    func testRunningAppsChangedReappliesAfterDebounce() {
        running.bundleIDs = ["left"]
        hideOneApp()
        running.bundleIDs = ["left", "new"]

        controller.runningAppsChanged()
        controller.runningAppsChanged()
        XCTAssertEqual(engine.restrictions.count, 1, "nothing until the burst settles")
        scheduler.fireAll()

        XCTAssertEqual(engine.restrictions.count, 2, "one reconcile per burst")
        XCTAssertTrue(engine.restrictions[1].contains("new"))
        XCTAssertFalse(engine.restrictions[1].contains("left"))
    }

    func testRunningAppsChangedSkipsIdenticalAllowList() {
        running.bundleIDs = ["left", "other"]
        hideOneApp()
        controller.runningAppsChanged()
        scheduler.fireAll()
        XCTAssertEqual(engine.restrictions.count, 1, "an unchanged allow list must not be re-sent")
    }

    func testRunningAppsChangedIgnoredWhileShown() {
        controller.runningAppsChanged()
        scheduler.fireAll()
        XCTAssertTrue(engine.restrictions.isEmpty)
    }

    // MARK: - Clock hover

    func testPointerOverClockReleasesAndRestoresAfterGrace() {
        hideOneApp()
        XCTAssertEqual(engine.restrictions.count, 1)

        controller.pointerOverClock = true
        XCTAssertEqual(engine.releases, 1, "restriction drops as soon as the pointer reaches the clock")
        XCTAssertEqual(controller.state, .hidden)

        controller.pointerOverClock = false
        XCTAssertEqual(engine.restrictions.count, 1, "restore waits for the grace period")
        scheduler.fireAll()
        XCTAssertEqual(engine.restrictions.count, 2)
    }

    func testReenteringClockCancelsPendingRestore() {
        hideOneApp()
        controller.pointerOverClock = true
        controller.pointerOverClock = false
        controller.pointerOverClock = true
        scheduler.fireAll()
        XCTAssertEqual(engine.restrictions.count, 1, "cancelled restore must not fire")
        XCTAssertEqual(engine.releases, 1)
    }

    func testRunningAppsChangedKeepsBarUnrestrictedWhilePointerOnClock() {
        hideOneApp()
        controller.pointerOverClock = true
        running.bundleIDs = ["new"]
        controller.runningAppsChanged()
        scheduler.fireAll()
        XCTAssertEqual(engine.restrictions.count, 1, "the clock hover must keep the bar unrestricted")
    }

    func testHoverIgnoredWhileShown() {
        controller.pointerOverClock = true
        controller.pointerOverClock = false
        scheduler.fireAll()
        XCTAssertEqual(engine.releases, 0)
        XCTAssertTrue(engine.restrictions.isEmpty)
    }

    func testShowWhilePointerOnClockDoesNotRestoreLater() {
        settings.autoHideSeconds = 0
        hideOneApp()
        controller.pointerOverClock = true
        controller.pointerOverClock = false
        controller.show()
        scheduler.fireAll()
        XCTAssertEqual(engine.restrictions.count, 1, "a pending hover restore must not re-hide after show")
    }

    // MARK: - Menu extras

    private let timeMachine = "com.apple.menuextra.TimeMachine"
    private let vpn = "com.apple.menuextra.vpn"

    private func hideTimeMachineAndOneApp() {
        extras.loaded = [vpn, timeMachine]
        items.positions = [
            .init(bundleID: "left", x: 100), .init(bundleID: timeMachine, x: 200), .init(bundleID: vpn, x: 900),
        ]
        controller.hide()
    }

    func testHideUnloadsOnlyExtrasBetweenSeparators() {
        hideTimeMachineAndOneApp()
        XCTAssertEqual(extras.removals, [timeMachine])
        XCTAssertEqual(settings.removedMenuExtraIDs, [timeMachine])
        XCTAssertTrue(engine.restrictions[0].contains("com.apple.systemuiserver"), "VPN must stay visible")
    }

    func testHidingOnlyExtrasHoldsNoRestriction() {
        extras.loaded = [timeMachine]
        items.positions = [.init(bundleID: timeMachine, x: 100)]
        controller.hide()
        XCTAssertEqual(extras.removals, [timeMachine])
        XCTAssertTrue(engine.restrictions.isEmpty, "assessment mode would block Notification Center for nothing")
    }

    func testShowReloadsUnloadedExtras() {
        hideTimeMachineAndOneApp()
        controller.show()
        XCTAssertEqual(extras.restorations, [timeMachine])
        XCTAssertEqual(settings.removedMenuExtraIDs, [])
    }

    func testPointerOverClockKeepsExtrasUnloaded() {
        hideTimeMachineAndOneApp()
        controller.pointerOverClock = true
        XCTAssertEqual(engine.releases, 1)
        XCTAssertTrue(extras.restorations.isEmpty)
    }

    func testStartReloadsExtrasLeftUnloadedByPreviousRun() {
        settings.removedMenuExtraIDs = [timeMachine]
        controller.start()
        XCTAssertEqual(extras.restorations, [timeMachine])
        XCTAssertEqual(settings.removedMenuExtraIDs, [])
    }

    func testShutdownReloadsExtras() {
        hideTimeMachineAndOneApp()
        controller.shutdown()
        XCTAssertEqual(extras.restorations, [timeMachine])
        XCTAssertEqual(settings.removedMenuExtraIDs, [])
    }

    func testFailedReloadIsRetriedLater() {
        hideTimeMachineAndOneApp()
        extras.failRestore = true
        controller.show()
        XCTAssertEqual(settings.removedMenuExtraIDs, [timeMachine], "an extra that failed to load must be retried")

        extras.failRestore = false
        controller.shutdown()
        XCTAssertEqual(extras.restorations, [timeMachine, timeMachine])
        XCTAssertEqual(settings.removedMenuExtraIDs, [])
    }

    func testAutoHideWhilePointerAlreadyOnClockStaysUnrestricted() {
        settings.autoHideSeconds = 5
        hideOneApp()
        controller.show()
        controller.pointerOverClock = true
        scheduler.fireAll()
        XCTAssertEqual(controller.state, .hidden)
        XCTAssertNil(engine.appliedAllowList, "the clock must stay clickable")
    }
}
