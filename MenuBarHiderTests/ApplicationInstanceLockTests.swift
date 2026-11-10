import XCTest

@testable import MenuBarHider

final class ApplicationInstanceLockTests: XCTestCase {
    func testDuplicateIsRejectedUntilOwnerReleasesLock() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("instance.lock")
        var owner = try ApplicationInstanceLock.acquire(url: url)
        XCTAssertNotNil(owner)
        try withExtendedLifetime(owner) {
            XCTAssertNil(try ApplicationInstanceLock.acquire(url: url))
        }

        owner = nil

        let replacement = try ApplicationInstanceLock.acquire(url: url)
        XCTAssertNotNil(replacement)
        try withExtendedLifetime(replacement) {
            XCTAssertNil(try ApplicationInstanceLock.acquire(url: url))
        }
    }

    func testLockTightensExistingDirectoryAndFilePermissions() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("instance.lock")
        try Data().write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

        let owner = try ApplicationInstanceLock.acquire(url: url)

        XCTAssertNotNil(owner)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
        withExtendedLifetime(owner) {}
    }

    func testLockFileSymlinkFailsWithoutChangingTarget() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target")
        let data = Data("preserve".utf8)
        try data.write(to: target)
        let url = directory.appendingPathComponent("instance.lock")
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)

        XCTAssertThrowsError(try ApplicationInstanceLock.acquire(url: url))
        XCTAssertEqual(try Data(contentsOf: target), data)
    }

    func testLockDirectorySymlinkFails() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try ApplicationInstanceLock.acquire(url: link.appendingPathComponent("instance.lock")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("instance.lock").path))
    }

    func testUnexpectedFilesystemErrorThrowsInsteadOfLookingLikeDuplicate() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("instance.lock")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)

        XCTAssertThrowsError(try ApplicationInstanceLock.acquire(url: url))
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}
