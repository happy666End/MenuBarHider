import CoreFoundation
import Foundation
import XCTest

@testable import MenuBarHider

final class SystemTrackedApplicationsStoreTests: XCTestCase {
    private final class PreferenceCalls {
        var events: [String] = []
        var value: CFPropertyList? = Data([0, 1, 255]) as CFData
        var synchronized = true
        var written: Data?

        func functions() -> SystemTrackedApplicationsStore.Functions {
            .init(
                copy: { key, application, user, host, container in
                    self.check(key, application, user, host, container)
                    self.events.append("copy")
                    return self.value.map { Unmanaged.passRetained($0) }
                },
                set: { key, value, application, user, host, container in
                    self.check(key, application, user, host, container)
                    self.events.append("set")
                    self.written = value as? Data
                },
                synchronize: { application, user, host, container in
                    self.check("trackedApplications" as CFString, application, user, host, container)
                    self.events.append("synchronize")
                    return self.synchronized
                })
        }

        private func check(
            _ key: CFString, _ application: CFString, _ user: CFString, _ host: CFString, _ container: CFString
        ) {
            XCTAssertEqual(key as String, "trackedApplications")
            XCTAssertEqual(application as String, "group.com.apple.controlcenter")
            XCTAssertEqual(user, kCFPreferencesCurrentUser)
            XCTAssertEqual(host, kCFPreferencesAnyHost)
            XCTAssertEqual(
                container as String,
                NSHomeDirectory() + "/Library/Group Containers/group.com.apple.controlcenter")
        }
    }

    func testInitializationDoesNotLoadOrAccessPreferences() {
        var loaded = false
        _ = SystemTrackedApplicationsStore(functions: {
            loaded = true
            return PreferenceCalls().functions()
        })
        XCTAssertFalse(loaded)
    }

    func testReadSynchronizesBeforeReturningRawData() throws {
        let calls = PreferenceCalls()
        let subject = SystemTrackedApplicationsStore(functions: calls.functions)
        XCTAssertEqual(try subject.read(), Data([0, 1, 255]))
        XCTAssertEqual(calls.events, ["synchronize", "copy"])
    }

    func testReadFailsBeforeCopyWhenSynchronizationFails() {
        let calls = PreferenceCalls()
        calls.synchronized = false
        let subject = SystemTrackedApplicationsStore(functions: calls.functions)
        XCTAssertThrowsError(try subject.read())
        XCTAssertEqual(calls.events, ["synchronize"])
    }

    func testReadRejectsMissingAndNonDataValues() {
        let calls = PreferenceCalls()
        let subject = SystemTrackedApplicationsStore(functions: calls.functions)
        calls.value = nil
        XCTAssertThrowsError(try subject.read())
        calls.value = "unexpected" as CFString
        XCTAssertThrowsError(try subject.read())
    }

    func testWriteUsesRawDataThenSynchronizes() throws {
        let calls = PreferenceCalls()
        let subject = SystemTrackedApplicationsStore(functions: calls.functions)
        try subject.write(Data([255, 2, 0]))
        XCTAssertEqual(calls.written, Data([255, 2, 0]))
        XCTAssertEqual(calls.events, ["set", "synchronize"])
    }

    func testFailedWriteSynchronizationIsReported() {
        let calls = PreferenceCalls()
        calls.synchronized = false
        let subject = SystemTrackedApplicationsStore(functions: calls.functions)
        XCTAssertThrowsError(try subject.write(Data([7])))
        XCTAssertEqual(calls.written, Data([7]))
        XCTAssertEqual(calls.events, ["set", "synchronize"])
    }

    func testUnavailablePrivateFunctionsFailReadAndWriteGracefully() {
        let subject = SystemTrackedApplicationsStore(functions: {
            throw SystemTrackedApplicationsStore.Failure.unavailable
        })
        XCTAssertThrowsError(try subject.read())
        XCTAssertThrowsError(try subject.write(Data()))
    }
}
