import AppKit
import XCTest

@testable import MenuBarHider

final class ApplicationRelaunchTests: XCTestCase {
    func testReplacementWaitsForOldProcessAndInstanceLock() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lockURL = directory.appendingPathComponent("instance.lock")
        var owner = try ApplicationInstanceLock.acquire(url: lockURL)
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sleep")
        parent.arguments = ["30"]
        try parent.run()
        defer {
            if parent.isRunning { parent.terminate() }
            parent.waitUntilExit()
        }
        let started = expectation(description: "handoff started")
        let launched = expectation(description: "replacement launched")
        let finished = expectation(description: "handoff finished")
        let marker = directory.appendingPathComponent("launched")
        DispatchQueue.global().async {
            started.fulfill()
            do {
                try ApplicationRelaunch.perform(
                    after: parent.processIdentifier, lockURL: lockURL, timeout: 3
                ) {
                    let replacement = try ApplicationInstanceLock.acquire(url: lockURL)
                    XCTAssertNotNil(replacement, "the launched app must be able to acquire the lock")
                    withExtendedLifetime(replacement) {}
                    try Data().write(to: marker)
                    launched.fulfill()
                }
            } catch {
                XCTFail("Handoff failed: \(error)")
            }
            finished.fulfill()
        }

        wait(for: [started], timeout: 1)
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "the old process is still alive")
        parent.terminate()
        parent.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "the old controller still owns the lock")
        owner = nil

        wait(for: [launched, finished], timeout: 4)
        XCTAssertNil(owner)
        XCTAssertNotNil(try ApplicationInstanceLock.acquire(url: lockURL), "the helper must release its own lock")
    }

    func testCancelledQuitTimesOutWithoutLaunchingReplacement() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("launched")

        XCTAssertThrowsError(
            try ApplicationRelaunch.perform(
                after: ProcessInfo.processInfo.processIdentifier,
                lockURL: directory.appendingPathComponent("instance.lock"), timeout: 0.05
            ) {
                try Data().write(to: marker)
            })

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testBusyLockTimesOutAfterOldProcessExitsWithoutLaunching() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lockURL = directory.appendingPathComponent("instance.lock")
        let owner = try ApplicationInstanceLock.acquire(url: lockURL)
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try parent.run()
        parent.waitUntilExit()
        let marker = directory.appendingPathComponent("launched")

        try withExtendedLifetime(owner) {
            XCTAssertThrowsError(
                try ApplicationRelaunch.perform(after: parent.processIdentifier, lockURL: lockURL, timeout: 0.05) {
                    try Data().write(to: marker)
                })
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
            XCTAssertNil(try ApplicationInstanceLock.acquire(url: lockURL))
        }
    }

    func testCancelledQuitDoesNotLeaveARelaunchForALaterTermination() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("launched")
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/usr/bin/touch")
        helper.arguments = [marker.path]
        let notifications = NotificationCenter()

        ApplicationRelaunch.requestTermination(helper: helper, notifications: notifications) {}
        notifications.post(name: NSApplication.willTerminateNotification, object: nil)

        XCTAssertEqual(helper.processIdentifier, 0, "cancelled termination must never spawn a helper")
        if helper.processIdentifier != 0 { helper.waitUntilExit() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testHelperStartsAfterTerminationIsApproved() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("launched")
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/usr/bin/touch")
        helper.arguments = [marker.path]
        let notifications = NotificationCenter()

        ApplicationRelaunch.requestTermination(helper: helper, notifications: notifications) {
            XCTAssertEqual(helper.processIdentifier, 0, "the user has not approved termination yet")
            notifications.post(name: NSApplication.willTerminateNotification, object: nil)
            XCTAssertGreaterThan(helper.processIdentifier, 0)
        }
        helper.waitUntilExit()

        XCTAssertEqual(helper.terminationStatus, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}
