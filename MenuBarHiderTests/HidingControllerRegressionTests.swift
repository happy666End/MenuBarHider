import XCTest

@testable import MenuBarHider

@MainActor
final class HidingControllerRegressionTests: XCTestCase {
    private var engine: FakeEngine!
    private var items: FakeItems!
    private var running: FakeRunning!
    private var settings: Settings!
    private var controller: HidingController!
    private var suite: String!

    override func setUp() {
        engine = FakeEngine()
        items = FakeItems()
        running = FakeRunning()
        suite = "HidingControllerRegressionTests-\(UUID().uuidString)"
        settings = Settings(defaults: UserDefaults(suiteName: suite)!)
        settings.autoHideSeconds = 0
        controller = HidingController(
            engine: engine, items: items, runningApps: running, extras: FakeExtras(),
            separators: { SeparatorPositions(separatorX: 500, leftSeparatorX: nil) },
            isInApplications: true, settings: settings, scheduler: ManualScheduler())
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    private func hideOneApp() {
        items.positions = [.init(bundleID: "left", x: 100)]
        controller.hide()
    }

    func testPartialScanRetainsFailedRunningAppButAcceptsObservedMovement() {
        running.bundleIDs = ["left", "other"]
        items.positions = [.init(bundleID: "left", x: 100), .init(bundleID: "other", x: 200)]
        controller.hide()
        controller.show()
        items.positions = [.init(bundleID: "left", x: 900)]
        items.failedBundleIDs = ["other"]

        controller.hide()

        XCTAssertEqual(controller.hiddenSet, ["other"])
        XCTAssertEqual(settings.hiddenBundleIDs, ["other"])
        XCTAssertFalse(engine.appliedAllowList?.contains("other") ?? true)
        XCTAssertTrue(engine.appliedAllowList?.contains("left") ?? false)
    }

    func testFailedScanDoesNotRetainAppConfirmedNoLongerRunning() {
        running.bundleIDs = ["left"]
        hideOneApp()
        controller.show()
        running.bundleIDs = []
        items.positions = []
        items.failedBundleIDs = ["left"]

        controller.hide()

        XCTAssertTrue(controller.hiddenSet.isEmpty)
    }

    func testFirstPartialScanProtectsUnobservedVisibleSiblingOfSharedOwner() throws {
        let owner: [String: Any] = ["bundle": ["_0": "fixture.host"]]
        let records: [Any] = [
            owner,
            [
                "location": owner, "isAllowed": true,
                "menuItemLocations": [
                    ["bundle": ["_0": "fixture.hidden"]], ["bundle": ["_0": "fixture.visible"]],
                ],
            ],
        ]
        let store = MemoryTrackedStore(
            data: try PropertyListSerialization.data(fromPropertyList: records, format: .binary, options: 0))
        let journal = MemoryVisibilityJournal()
        running.bundleIDs = ["fixture.hidden", "fixture.visible"]
        let native = NativeHidingEngine(
            store: store, journal: journal, runningApps: running, parentBundleIDs: { _ in [] })
        settings.hidingMethod = .systemSettings
        let router = HidingEngineRouter(settings: settings, assessment: engine, native: native)
        let subject = HidingController(
            engine: router, items: items, runningApps: running, extras: FakeExtras(),
            separators: { SeparatorPositions(separatorX: 500, leftSeparatorX: nil) },
            isInApplications: true, settings: settings, scheduler: ManualScheduler())
        items.positions = [.init(bundleID: "fixture.hidden", x: 100)]
        items.failedBundleIDs = ["fixture.visible"]

        subject.hide()

        guard case NativeHidingFailure.sharedVisibleOwner? = subject.lastError else {
            return XCTFail("An unreadable visible sibling must protect its shared switch")
        }
        XCTAssertEqual(store.writes, 0)
        XCTAssertTrue(journal.owned.isEmpty)
        XCTAssertEqual(try TrackedApplicationsDocument(data: store.data).states()["fixture.host"], true)

        subject.show()
        items.failedBundleIDs = []
        subject.hide()

        XCTAssertNil(subject.lastError)
        XCTAssertEqual(try TrackedApplicationsDocument(data: store.data).states()["fixture.host"], false)
        XCTAssertEqual(journal.owned, ["fixture.host"])
        XCTAssertTrue(subject.shutdown())
    }

    func testClockHoverDoesNotReleaseSystemSettingsEngine() {
        engine.requiresClockHover = false
        hideOneApp()

        controller.pointerOverClock = true

        XCTAssertEqual(engine.releases, 0)
        XCTAssertNotNil(engine.appliedAllowList)
    }

    func testReturnToAppliedListStillSupersedesPendingRequest() {
        let delayed = RecordingPendingEngine()
        let scheduler = ManualScheduler()
        items.positions = [.init(bundleID: "left", x: 100)]
        running.bundleIDs = ["left", "visible.a"]
        let subject = HidingController(
            engine: delayed, items: items, runningApps: running, extras: FakeExtras(),
            separators: { SeparatorPositions(separatorX: 500, leftSeparatorX: nil) },
            isInApplications: true, settings: settings, scheduler: scheduler)
        subject.hide()
        delayed.finishFirst()
        running.bundleIDs = ["left", "visible.b"]
        subject.runningAppsChanged()
        scheduler.fireAll()
        running.bundleIDs = ["left", "visible.a"]
        subject.runningAppsChanged()

        scheduler.fireAll()

        let requests = delayed.requests.map { $0.filter { $0.hasPrefix("visible.") } }
        XCTAssertEqual(requests, [["visible.a"], ["visible.b"], ["visible.a"]])
    }

    func testExplicitRecoveryDoesNotAutomaticallyHideAgain() {
        settings.autoHideSeconds = 10
        let scheduler = ManualScheduler()
        let subject = HidingController(
            engine: engine, items: items, runningApps: running, extras: FakeExtras(),
            separators: { SeparatorPositions(separatorX: 500, leftSeparatorX: nil) },
            isInApplications: true, settings: settings, scheduler: scheduler)
        items.positions = [.init(bundleID: "left", x: 100)]
        subject.hide()

        subject.restoreVisibility()
        scheduler.fireAll()

        XCTAssertEqual(subject.state, .shown)
        XCTAssertNil(engine.appliedAllowList)
        subject.toggle()
        XCTAssertEqual(subject.state, .hidden)
    }

    func testExplicitRecoveryCancelsStartupPermissionRetry() {
        let scheduler = ManualScheduler()
        items.isTrusted = false
        let subject = HidingController(
            engine: engine, items: items, runningApps: running, extras: FakeExtras(),
            separators: { SeparatorPositions(separatorX: 500, leftSeparatorX: nil) },
            isInApplications: true, settings: settings, scheduler: scheduler)
        subject.start()
        scheduler.fireAll()

        subject.restoreVisibility()
        items.isTrusted = true
        scheduler.fireAll()

        XCTAssertEqual(subject.state, .shown)
        XCTAssertNil(engine.appliedAllowList)
        subject.toggle()
        XCTAssertEqual(subject.state, .hidden)
    }
}

private final class RecordingPendingEngine: HidingEngine {
    let isAvailable = true
    var appliedAllowList: [String]?
    var requestedAllowList: [String]?
    var requests: [[String]] = []
    private var firstCompletion: ((Error?) -> Void)?

    func restrict(allowedBundleIDs: [String], completion: @escaping (Error?) -> Void) {
        requestedAllowList = allowedBundleIDs
        requests.append(allowedBundleIDs)
        if requests.count == 1 { firstCompletion = completion }
    }

    func finishFirst() {
        appliedAllowList = requests[0]
        firstCompletion?(nil)
    }

    func release() {
        requestedAllowList = nil
        appliedAllowList = nil
    }
}
