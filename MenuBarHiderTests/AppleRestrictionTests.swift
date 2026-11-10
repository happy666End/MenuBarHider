import XCTest

@testable import MenuBarHider

@MainActor
final class AppleRestrictionTests: XCTestCase {
    func testSystemOnlySelectionActivatesRestrictionWithoutSendingFakeBundleIDs() {
        withFixture { fixture in
            fixture.items.positions = [.init(bundleID: "system-item:wifi", x: 200)]
            fixture.controller.hide()
            XCTAssertEqual(fixture.engine.requests.last?.hiddenSystemItems, [6])
            XCTAssertFalse(fixture.engine.requests.last?.allowedBundleIDs.contains("system-item:wifi") ?? true)
        }
    }

    func testSameAppAllowListWithDifferentPendingSystemSelectionIsReplaced() {
        withFixture { fixture in
            fixture.running.bundleIDs = ["visible.app"]
            fixture.engine.pending = MenuBarRestriction(
                allowedBundleIDs: Array(Set(["visible.app"]).union(SystemItems.alwaysAllowedBundleIDs)).sorted(),
                hiddenSystemItems: [4])
            fixture.items.positions = [.init(bundleID: "system-item:wifi", x: 200)]
            fixture.controller.hide()
            XCTAssertEqual(fixture.engine.requests.last?.hiddenSystemItems, [6])
        }
    }

    func testFailedSystemScanKeepsPersistedSelectionWithoutARunningBundle() {
        withFixture { fixture in
            fixture.items.positions = [.init(bundleID: "system-item:wifi", x: 200)]
            fixture.controller.hide()
            fixture.controller.show()
            fixture.items.positions = []
            fixture.items.failedBundleIDs = ["system-item:wifi"]
            fixture.controller.hide()
            XCTAssertEqual(fixture.controller.hiddenSet, ["system-item:wifi"])
            XCTAssertEqual(fixture.engine.requests.last?.hiddenSystemItems, [6])
        }
    }

    func testNativeUnsupportedSelectionDoesNotUnloadExtrasOrWritePreferences() throws {
        try withFixture { fixture in
            let store = MemoryTrackedStore(
                data: try PropertyListSerialization.data(
                    fromPropertyList: [], format: .binary, options: 0))
            let journal = MemoryVisibilityJournal()
            fixture.settings.hidingMethod = .systemSettings
            fixture.running.bundleIDs = ["com.apple.TextInputMenuAgent"]
            let native = NativeHidingEngine(
                store: store, journal: journal, runningApps: fixture.running, parentBundleIDs: { _ in [] })
            let router = HidingEngineRouter(settings: fixture.settings, assessment: fixture.engine, native: native)
            let controller = fixture.makeController(engine: router)
            fixture.extras.loaded = ["com.apple.menuextra.vpn"]
            fixture.items.positions = [
                .init(bundleID: "com.apple.TextInputMenuAgent", x: 200),
                .init(bundleID: "com.apple.menuextra.vpn", x: 250),
            ]
            controller.hide()
            XCTAssertTrue(controller.lastError?.localizedDescription.contains("Compatibility") ?? false)
            XCTAssertEqual(store.writes, 0)
            XCTAssertTrue(journal.owned.isEmpty)
            XCTAssertTrue(fixture.extras.removals.isEmpty)
            XCTAssertEqual(fixture.settings.hidingMethod, .systemSettings)
        }
    }

    private func withFixture(_ body: (AppleRestrictionFixture) throws -> Void) rethrows {
        let fixture = AppleRestrictionFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        try body(fixture)
    }
}

@MainActor
private final class AppleRestrictionFixture {
    let suite = "AppleRestrictionTests-\(UUID().uuidString)"
    let defaults: UserDefaults
    let settings: Settings
    let engine = SystemRecordingEngine()
    let items = FakeItems()
    let running = FakeRunning()
    let extras = FakeExtras()
    lazy var controller = makeController(engine: engine)

    init() {
        defaults = UserDefaults(suiteName: suite)!
        settings = Settings(defaults: defaults)
        settings.autoHideSeconds = 0
    }

    func makeController(engine: HidingEngine) -> HidingController {
        HidingController(
            engine: engine, items: items, runningApps: running, extras: extras,
            separators: { .init(separatorX: 500, leftSeparatorX: 100) }, isInApplications: true,
            settings: settings, scheduler: ManualScheduler())
    }
}

private final class SystemRecordingEngine: HidingEngine {
    var isAvailable = true
    var requests: [MenuBarRestriction] = []
    var pending: MenuBarRestriction?
    var requestedRestriction: MenuBarRestriction? { pending }
    var appliedAllowList: [String]? { requests.last?.allowedBundleIDs }
    var requestedAllowList: [String]? { pending?.allowedBundleIDs }

    func validate(_ restriction: MenuBarRestriction) throws {}
    func restrict(_ restriction: MenuBarRestriction, completion: @escaping (Error?) -> Void) {
        pending = restriction
        requests.append(restriction)
        completion(nil)
    }
    func restrict(allowedBundleIDs: [String], completion: @escaping (Error?) -> Void) {
        restrict(MenuBarRestriction(allowedBundleIDs: allowedBundleIDs), completion: completion)
    }
    func release() { pending = nil }
}
