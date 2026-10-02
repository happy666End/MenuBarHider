import XCTest

@testable import MenuBarHider

final class AppLocationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AppLocationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        let readOnly = root.appendingPathComponent("ro").path
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly)
        try FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: - isInApplications

    func testAppUnderApplicationsCounts() {
        XCTAssertTrue(AppLocation.isInApplications(URL(fileURLWithPath: "/Applications/MenuBarHider.app")))
        XCTAssertTrue(AppLocation.isInApplications(URL(fileURLWithPath: "/Applications/Tools/MenuBarHider.app")))
    }

    func testAppElsewhereDoesNotCount() {
        let paths = [
            "/Users/me/Downloads/MenuBarHider.app",
            "/Volumes/MenuBarHider/MenuBarHider.app",
            "/private/var/folders/xy/abc/T/AppTranslocation/1234/d/MenuBarHider.app",
            "/Users/me/Applications/MenuBarHider.app",
            "/Applications Old/MenuBarHider.app",
        ]
        for path in paths {
            XCTAssertFalse(AppLocation.isInApplications(URL(fileURLWithPath: path)), path)
        }
    }

    // MARK: - install

    func testInstallMovesTheBundle() throws {
        let source = try makeBundle(in: root.appendingPathComponent("Downloads"), marker: "new")
        let target = root.appendingPathComponent("Applications")

        let installed = try AppLocation.install(source, into: target)

        XCTAssertEqual(installed, target.appendingPathComponent("MenuBarHider.app"))
        XCTAssertEqual(try marker(of: installed), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "a movable source leaves no stray copy")
    }

    func testInstallReplacesAnOlderCopy() throws {
        let target = root.appendingPathComponent("Applications")
        _ = try makeBundle(in: target, marker: "old")
        let source = try makeBundle(in: root.appendingPathComponent("Downloads"), marker: "new")

        let installed = try AppLocation.install(source, into: target)

        XCTAssertEqual(installed, target.appendingPathComponent("MenuBarHider.app"))
        XCTAssertEqual(try marker(of: installed), "new")
    }

    func testInstallCopiesWhenTheSourceCannotMove() throws {
        let readOnly = root.appendingPathComponent("ro")
        let source = try makeBundle(in: readOnly, marker: "new")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
        let target = root.appendingPathComponent("Applications")

        let installed = try AppLocation.install(source, into: target)

        XCTAssertEqual(installed, target.appendingPathComponent("MenuBarHider.app"))
        XCTAssertEqual(try marker(of: installed), "new")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testInstallRecoversFromAMoveThatCopiedButCouldNotDelete() throws {
        let source = try makeBundle(in: root.appendingPathComponent("Volume"), marker: "new")
        let target = root.appendingPathComponent("Applications")

        let installed = try AppLocation.install(source, into: target, fileManager: CrossVolumeFileManager())

        XCTAssertEqual(try marker(of: installed), "new")
    }

    // MARK: - Helpers

    private func makeBundle(in folder: URL, marker: String) throws -> URL {
        let bundle = folder.appendingPathComponent("MenuBarHider.app")
        let contents = bundle.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try marker.write(to: contents.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
        return bundle
    }

    private func marker(of bundle: URL) throws -> String {
        try String(contentsOf: bundle.appendingPathComponent("Contents/marker"), encoding: .utf8)
    }
}

private final class CrossVolumeFileManager: FileManager {
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        try copyItem(at: srcURL, to: dstURL)
        throw CocoaError(.fileWriteNoPermission)
    }
}
