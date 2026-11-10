import XCTest

@testable import MenuBarHider

final class NativeVisibilityJournalTests: XCTestCase {
    func testMissingJournalLoadsEmpty() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertEqual(
            try FileNativeVisibilityJournal(url: directory.appendingPathComponent("journal.json")).load(), [])
    }

    func testEmptySaveClearsPersistedRecovery() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("journal.json")
        let journal = FileNativeVisibilityJournal(url: url)
        try journal.save(["app.a"])

        try journal.save([])

        XCTAssertEqual(try FileNativeVisibilityJournal(url: url).load(), [])
    }

    func testInaccessibleJournalDoesNotLoadAsEmpty() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("journal.json")
        try FileNativeVisibilityJournal(url: url).save(["app.a"])
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }

        XCTAssertThrowsError(try FileNativeVisibilityJournal(url: url).load())
    }

    func testMalformedJournalFailsWithoutDiscardingIt() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("journal.json")
        let data = Data("malformed".utf8)
        try data.write(to: url)

        XCTAssertThrowsError(try FileNativeVisibilityJournal(url: url).load())
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testWriteFailureDoesNotReplaceExistingDirectory() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("journal.json")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)

        XCTAssertThrowsError(try FileNativeVisibilityJournal(url: url).save(["app.a"]))
        XCTAssertTrue(try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
    }

    func testJournalIsPrivateAndSurvivesNewInstance() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("journal.json")
        let journal = FileNativeVisibilityJournal(url: url)

        try journal.save(["app.a", "app.b"])

        XCTAssertEqual(try FileNativeVisibilityJournal(url: url).load(), ["app.a", "app.b"])
        let fileMode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        let folderMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        XCTAssertEqual(fileMode, 0o600)
        XCTAssertEqual(folderMode, 0o700)
    }

    func testUnknownJournalVersionFailsWithoutDiscardingIt() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = Data("{\"version\":2,\"bundleIDs\":[\"app.a\"]}".utf8)
        try data.write(to: url)

        XCTAssertThrowsError(try FileNativeVisibilityJournal(url: url).load())
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}
