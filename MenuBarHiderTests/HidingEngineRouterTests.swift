import XCTest

@testable import MenuBarHider

final class HidingEngineRouterTests: XCTestCase {
    private var suite: String!
    private var settings: Settings!
    private var store: MemoryTrackedStore!
    private var journal: MemoryVisibilityJournal!
    private var native: NativeHidingEngine!
    private var legacy: FakeEngine!
    private var router: HidingEngineRouter!

    override func setUpWithError() throws {
        suite = "HidingEngineRouterTests-\(UUID().uuidString)"
        settings = Settings(defaults: UserDefaults(suiteName: suite)!)
        let key: [String: Any] = ["bundle": ["_0": "app.a"]]
        let array: [Any] = [key, ["location": key, "isAllowed": true, "menuItemLocations": [key]]]
        store = MemoryTrackedStore(
            data: try PropertyListSerialization.data(
                fromPropertyList: array, format: .binary, options: 0))
        journal = MemoryVisibilityJournal()
        let running = FakeRunning()
        running.bundleIDs = ["app.a"]
        native = NativeHidingEngine(store: store, journal: journal, runningApps: running, parentBundleIDs: { _ in [] })
        legacy = FakeEngine()
        router = HidingEngineRouter(settings: settings, assessment: legacy, native: native)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testDefaultRemainsCompatibility() {
        XCTAssertEqual(router.method, .assessment)
        XCTAssertTrue(router.requiresClockHover)
        XCTAssertEqual(store.writes, 0)
    }

    func testExplicitNativeSelectionDisablesClockHover() throws {
        try router.select(.systemSettings)

        XCTAssertEqual(router.method, .systemSettings)
        XCTAssertEqual(settings.hidingMethod, .systemSettings)
        XCTAssertFalse(router.requiresClockHover)
    }

    func testSwitchingBackRestoresNativeFlagsFirst() throws {
        try router.select(.systemSettings)
        router.restrict(allowedBundleIDs: []) { XCTAssertNil($0) }
        XCTAssertEqual(journal.owned, ["app.a"])

        try router.select(.assessment)

        XCTAssertTrue(journal.owned.isEmpty)
        XCTAssertEqual(try TrackedApplicationsDocument(data: store.data).states()["app.a"], true)
        XCTAssertEqual(router.method, .assessment)
    }

    func testFailedRestoreBlocksCompatibilityAndRetainsOwnership() throws {
        try router.select(.systemSettings)
        router.restrict(allowedBundleIDs: []) { XCTAssertNil($0) }
        store.writeError = Boom()

        XCTAssertThrowsError(try router.select(.assessment))

        XCTAssertEqual(router.method, .systemSettings)
        XCTAssertEqual(settings.hidingMethod, .systemSettings)
        XCTAssertEqual(journal.owned, ["app.a"])
        XCTAssertTrue(legacy.restrictions.isEmpty)
        XCTAssertNotNil(router.lastOperationError)
    }

    func testStartupRecoversJournalEvenWhenCompatibilitySelected() throws {
        store.data = try TrackedApplicationsDocument(data: store.data).settingAllowed(["app.a": false])
        journal.owned = ["app.a"]

        router = HidingEngineRouter(settings: settings, assessment: legacy, native: native)

        XCTAssertTrue(router.isAvailable)
        XCTAssertTrue(journal.owned.isEmpty)
        XCTAssertEqual(try TrackedApplicationsDocument(data: store.data).states()["app.a"], true)
        XCTAssertTrue(legacy.restrictions.isEmpty)
    }

    func testStartupRecoveryFailurePreventsAnyAssessmentActivation() {
        journal.owned = ["app.a"]
        store.readError = Boom()
        router = HidingEngineRouter(settings: settings, assessment: legacy, native: native)

        XCTAssertFalse(router.isAvailable)
        router.restrict(allowedBundleIDs: []) { XCTAssertNotNil($0) }

        XCTAssertTrue(legacy.restrictions.isEmpty)
        XCTAssertEqual(journal.owned, ["app.a"])
    }

    func testUnreadableNativeSettingsLeaveMethodUnchanged() {
        store.readError = Boom()

        XCTAssertThrowsError(try router.select(.systemSettings))

        XCTAssertEqual(router.method, .assessment)
        XCTAssertEqual(settings.hidingMethod, .assessment)
        XCTAssertEqual(store.writes, 0)
    }

    @MainActor
    func testMethodSwitchPreservesSelectionDuringTemporaryEmptyLayout() {
        settings.autoHideSeconds = 0
        let items = FakeItems()
        items.positions = [.init(bundleID: "app.a", x: 100)]
        let running = FakeRunning()
        running.bundleIDs = ["app.a"]
        let controller = HidingController(
            engine: router, items: items, runningApps: running, extras: FakeExtras(),
            separators: { SeparatorPositions(separatorX: 500, leftSeparatorX: nil) },
            isInApplications: true, settings: settings, scheduler: ManualScheduler())
        controller.hide()
        XCTAssertEqual(controller.hiddenSet, ["app.a"])
        items.positions = []

        controller.setHidingMethod(.systemSettings)

        XCTAssertEqual(controller.hiddenSet, ["app.a"])
        XCTAssertEqual(settings.hiddenBundleIDs, ["app.a"])
        XCTAssertEqual(controller.state, .hidden)
        XCTAssertEqual(journal.owned, ["app.a"])
        controller.shutdown()
    }

    @MainActor
    func testStartupRecoveryErrorIsVisibleWithoutAnotherHide() {
        journal.owned = ["app.a"]
        store.readError = Boom()
        router = HidingEngineRouter(settings: settings, assessment: legacy, native: native)
        let controller = HidingController(
            engine: router, items: FakeItems(), runningApps: FakeRunning(), extras: FakeExtras(),
            separators: { SeparatorPositions(separatorX: 500, leftSeparatorX: nil) },
            isInApplications: true, settings: settings, scheduler: ManualScheduler())

        controller.start()

        XCTAssertNotNil(controller.lastError)
    }

    @MainActor
    func testShutdownSurfacesUnrestoredNativeFlags() throws {
        settings.autoHideSeconds = 0
        try router.select(.systemSettings)
        let items = FakeItems()
        items.positions = [.init(bundleID: "app.a", x: 100)]
        let running = FakeRunning()
        running.bundleIDs = ["app.a"]
        let controller = HidingController(
            engine: router, items: items, runningApps: running, extras: FakeExtras(),
            separators: { SeparatorPositions(separatorX: 500, leftSeparatorX: nil) },
            isInApplications: true, settings: settings, scheduler: ManualScheduler())
        controller.hide()
        store.writeError = Boom()

        controller.shutdown()

        XCTAssertNotNil(controller.lastError)
        XCTAssertEqual(journal.owned, ["app.a"])
    }
}
