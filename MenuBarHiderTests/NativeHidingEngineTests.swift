import XCTest

@testable import MenuBarHider

final class NativeHidingEngineTests: XCTestCase {
    private var store: MemoryTrackedStore!
    private var journal: MemoryVisibilityJournal!
    private var running: FakeRunning!
    private var engine: NativeHidingEngine!

    override func setUpWithError() throws {
        store = MemoryTrackedStore(data: try Self.fixture())
        journal = MemoryVisibilityJournal()
        running = FakeRunning()
        running.bundleIDs = ["app.a", "app.b"]
        engine = NativeHidingEngine(store: store, journal: journal, runningApps: running, parentBundleIDs: { _ in [] })
    }

    private static func fixture(firstAllowed: Bool = true, secondAllowed: Bool = true) throws -> Data {
        struct Record {
            let id: String
            let allowed: Bool
            let locations: [String]
        }
        let records = [
            Record(id: "app.a", allowed: firstAllowed, locations: ["app.a"]),
            Record(id: "app.b", allowed: secondAllowed, locations: ["app.b"]),
            Record(id: "app.disabled", allowed: false, locations: ["app.disabled"]),
            Record(id: "app.host", allowed: true, locations: ["app.helper"]),
        ]
        var array: [Any] = []
        for record in records {
            let key: [String: Any] = ["bundle": ["_0": record.id]]
            array.append(key)
            array.append(
                [
                    "location": key, "isAllowed": record.allowed, "future": "preserve",
                    "menuItemLocations": record.locations.map { ["bundle": ["_0": $0]] },
                ] as [String: Any])
        }
        return try PropertyListSerialization.data(fromPropertyList: array, format: .binary, options: 0)
    }

    private func hideA() -> Error? {
        var result: Error?
        engine.restrict(allowedBundleIDs: ["app.b"]) { result = $0 }
        return result
    }

    private func states() throws -> [String: Bool] {
        try TrackedApplicationsDocument(data: store.data).states()
    }

    func testHideJournalsBeforeWritingAndShowRestoresOnlyOwnedFlags() throws {
        var events: [String] = []
        journal.onSave = { _ in events.append("journal") }
        store.onWrite = { events.append("write") }

        XCTAssertNil(hideA())
        XCTAssertEqual(events.first, "journal")
        XCTAssertEqual(try states()["app.a"], false)
        XCTAssertEqual(try states()["app.disabled"], false)
        XCTAssertEqual(journal.owned, ["app.a"])

        engine.release()

        XCTAssertNil(engine.lastOperationError)
        XCTAssertEqual(try states()["app.a"], true)
        XCTAssertEqual(try states()["app.disabled"], false)
        XCTAssertTrue(journal.owned.isEmpty)
        XCTAssertNil(engine.appliedAllowList)
    }

    func testPreviouslyDisabledAppIsNotOwnedOrEnabledOnShow() throws {
        store.data = try Self.fixture(firstAllowed: false)

        XCTAssertNil(hideA())
        engine.release()

        XCTAssertEqual(try states()["app.a"], false)
        XCTAssertTrue(journal.owned.isEmpty)
        XCTAssertEqual(store.writes, 0)
    }

    func testJournalFailurePreventsSystemWrite() throws {
        journal.saveError = Boom()

        XCTAssertNotNil(hideA())

        XCTAssertEqual(store.writes, 0)
        XCTAssertEqual(try states()["app.a"], true)
        XCTAssertNil(engine.appliedAllowList)
    }

    func testWriteFailureRetainsRecoveryJournal() {
        store.writeError = Boom()

        XCTAssertNotNil(hideA())

        XCTAssertEqual(journal.owned, ["app.a"])
        XCTAssertNil(engine.appliedAllowList)
    }

    func testReadbackFailureIsNotReportedAsApplied() {
        store.ignoreWrites = true

        XCTAssertNotNil(hideA())

        XCTAssertEqual(journal.owned, ["app.a"])
        XCTAssertNil(engine.appliedAllowList)
    }

    func testReadFailureDoesNotChangeJournalOrPreferences() {
        store.readError = Boom()

        XCTAssertNotNil(hideA())

        XCTAssertEqual(store.writes, 0)
        XCTAssertTrue(journal.owned.isEmpty)
    }

    func testRecoveryAfterNewEngineInstanceRestoresRecordedFlags() throws {
        XCTAssertNil(hideA())
        let restarted = NativeHidingEngine(
            store: store, journal: journal, runningApps: running, parentBundleIDs: { _ in [] })

        try restarted.recover()

        XCTAssertEqual(try states()["app.a"], true)
        XCTAssertTrue(journal.owned.isEmpty)
    }

    func testUnrelatedExternalChangeSurvivesRestore() throws {
        XCTAssertNil(hideA())
        store.data = try TrackedApplicationsDocument(data: store.data).settingAllowed(["app.b": false])

        engine.release()

        XCTAssertEqual(try states()["app.a"], true)
        XCTAssertEqual(try states()["app.b"], false)
    }

    func testExternalEnableSurvivesAndClearsOwnershipWithoutWriting() throws {
        XCTAssertNil(hideA())
        store.data = try TrackedApplicationsDocument(data: store.data).settingAllowed(["app.a": true])
        let writes = store.writes

        engine.release()

        XCTAssertEqual(try states()["app.a"], true)
        XCTAssertEqual(store.writes, writes)
        XCTAssertTrue(journal.owned.isEmpty)
    }

    func testHelperResolvesToRegisteredOwner() throws {
        running.bundleIDs = ["app.helper", "app.b"]
        XCTAssertNil(hideA())

        XCTAssertEqual(try states()["app.host"], false)
        XCTAssertEqual(journal.owned, ["app.host"])
    }

    func testUnknownOwnerFailsBeforeChangingAnyApp() throws {
        running.bundleIDs = ["app.a", "app.unknown", "app.b"]

        XCTAssertNotNil(hideA())

        XCTAssertEqual(store.writes, 0)
        XCTAssertTrue(journal.owned.isEmpty)
        XCTAssertEqual(try states()["app.a"], true)
    }

    func testRepeatedRequestDoesNotWriteAgain() {
        XCTAssertNil(hideA())
        let writes = store.writes

        XCTAssertNil(hideA())

        XCTAssertEqual(store.writes, writes)
    }

    func testRapidRoundTripHonoursLastRequest() throws {
        XCTAssertNil(hideA())
        engine.restrict(allowedBundleIDs: ["app.a"]) { XCTAssertNil($0) }
        XCTAssertNil(hideA())

        XCTAssertEqual(try states()["app.a"], false)
        XCTAssertEqual(try states()["app.b"], true)
        XCTAssertEqual(journal.owned, ["app.a"])
        XCTAssertEqual(engine.appliedAllowList, ["app.b"])
    }

    func testFailedRestoreRetainsJournalAndCanBeRetried() throws {
        XCTAssertNil(hideA())
        store.writeError = Boom()

        engine.release()

        XCTAssertNotNil(engine.lastOperationError)
        XCTAssertEqual(journal.owned, ["app.a"])
        store.writeError = nil
        engine.release()
        XCTAssertNil(engine.lastOperationError)
        XCTAssertTrue(journal.owned.isEmpty)
        XCTAssertEqual(try states()["app.a"], true)
    }

    func testFailedAcknowledgementCanReturnToPreviouslyAppliedRequest() throws {
        XCTAssertNil(hideA())
        store.failAfterWrite = true
        engine.restrict(allowedBundleIDs: ["app.a"]) { XCTAssertNotNil($0) }
        XCTAssertEqual(try states()["app.a"], true)
        XCTAssertEqual(try states()["app.b"], false)
        XCTAssertNil(engine.requestedAllowList)
        store.failAfterWrite = false

        XCTAssertNil(hideA())

        XCTAssertEqual(try states()["app.a"], false)
        XCTAssertEqual(try states()["app.b"], true)
        XCTAssertEqual(journal.owned, ["app.a"])
    }

    func testSharedOwnerCannotHideAnObservedVisibleSibling() throws {
        let key: [String: Any] = ["bundle": ["_0": "app.host"]]
        let records: [Any] = [
            key,
            [
                "location": key, "isAllowed": true,
                "menuItemLocations": [["bundle": ["_0": "app.helper"]], ["bundle": ["_0": "app.visible-helper"]]],
            ],
        ]
        store.data = try PropertyListSerialization.data(fromPropertyList: records, format: .binary, options: 0)
        running.bundleIDs = ["app.helper", "app.visible-helper"]
        engine.updateObservedBundleIDs(["app.helper", "app.visible-helper"])
        var failure: Error?

        engine.restrict(allowedBundleIDs: ["app.visible-helper"]) { failure = $0 }

        XCTAssertNotNil(failure)
        XCTAssertEqual(store.writes, 0)
        XCTAssertTrue(journal.owned.isEmpty)
    }

    func testRunningParentWithoutMenuItemDoesNotPreventHidingItsHelper() throws {
        running.bundleIDs = ["app.helper", "app.host"]
        engine.updateObservedBundleIDs(["app.helper"])

        engine.restrict(allowedBundleIDs: ["app.host"]) { XCTAssertNil($0) }

        XCTAssertEqual(try states()["app.host"], false)
    }
}

final class MemoryTrackedStore: TrackedApplicationsStore {
    var data: Data
    var readError: Error?
    var writeError: Error?
    var ignoreWrites = false
    var failAfterWrite = false
    var writes = 0
    var onWrite: (() -> Void)?

    init(data: Data) { self.data = data }

    func read() throws -> Data {
        if let readError { throw readError }
        return data
    }

    func write(_ data: Data) throws {
        writes += 1
        onWrite?()
        if let writeError { throw writeError }
        if !ignoreWrites { self.data = data }
        if failAfterWrite { throw Boom() }
    }
}

final class MemoryVisibilityJournal: NativeVisibilityJournal {
    var owned: Set<String> = []
    var saveError: Error?
    var onSave: ((Set<String>) -> Void)?

    func load() throws -> Set<String> { owned }
    func save(_ bundleIDs: Set<String>) throws {
        if let saveError { throw saveError }
        onSave?(bundleIDs)
        owned = bundleIDs
    }
}
