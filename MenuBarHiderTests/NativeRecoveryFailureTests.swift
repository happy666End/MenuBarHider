import XCTest

@testable import MenuBarHider

final class NativeRecoveryFailureTests: XCTestCase {
    private var store: MemoryTrackedStore!
    private var journal: FailingRecoveryJournal!
    private var engine: NativeHidingEngine!

    override func setUpWithError() throws {
        let key: [String: Any] = ["bundle": ["_0": "app.a"]]
        let array: [Any] = [key, ["location": key, "isAllowed": true, "menuItemLocations": [key]]]
        store = MemoryTrackedStore(
            data: try PropertyListSerialization.data(
                fromPropertyList: array, format: .binary, options: 0))
        journal = FailingRecoveryJournal()
        let running = FakeRunning()
        running.bundleIDs = ["app.a"]
        engine = NativeHidingEngine(store: store, journal: journal, runningApps: running, parentBundleIDs: { _ in [] })
    }

    func testUnreadableJournalPreventsAnySystemWrite() {
        journal.readError = Boom()

        engine.restrict(allowedBundleIDs: []) { XCTAssertNotNil($0) }

        XCTAssertEqual(store.writes, 0)
        XCTAssertNil(engine.appliedAllowList)
    }

    func testFailedJournalClearLeavesRecoveryBlockedUntilRetry() throws {
        engine.restrict(allowedBundleIDs: []) { XCTAssertNil($0) }
        journal.failClear = true

        engine.release()

        XCTAssertNotNil(engine.lastOperationError)
        XCTAssertEqual(journal.owned, ["app.a"])
        XCTAssertEqual(try TrackedApplicationsDocument(data: store.data).states()["app.a"], true)
        journal.failClear = false
        engine.release()
        XCTAssertNil(engine.lastOperationError)
        XCTAssertTrue(journal.owned.isEmpty)
    }

    func testUnverifiedRestoreRetainsJournal() {
        engine.restrict(allowedBundleIDs: []) { XCTAssertNil($0) }
        store.ignoreWrites = true

        engine.release()

        XCTAssertNotNil(engine.lastOperationError)
        XCTAssertEqual(journal.owned, ["app.a"])
        XCTAssertNotNil(engine.appliedAllowList)
    }
}

private final class FailingRecoveryJournal: NativeVisibilityJournal {
    var owned: Set<String> = []
    var readError: Error?
    var failClear = false

    func load() throws -> Set<String> {
        if let readError { throw readError }
        return owned
    }

    func save(_ bundleIDs: Set<String>) throws {
        if bundleIDs.isEmpty && failClear { throw Boom() }
        owned = bundleIDs
    }
}
