import Darwin
import Foundation

protocol NativeVisibilityJournal {
    func load() throws -> Set<String>
    func save(_ bundleIDs: Set<String>) throws
}

final class FileNativeVisibilityJournal: NativeVisibilityJournal {
    private struct Record: Codable {
        let version: Int
        let bundleIDs: [String]
    }

    enum Failure: LocalizedError {
        case unsupportedVersion
        var errorDescription: String? { "The visibility recovery journal has an unsupported format." }
    }

    let url: URL

    init(url: URL = FileNativeVisibilityJournal.defaultURL) { self.url = url }

    static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/MenuBarHider/native-visibility.json")
    }

    func load() throws -> Set<String> {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileReadNoSuchFile.rawValue {
                return []
            }
            if error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { return [] }
            throw error
        }
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard record.version == 1 else { throw Failure.unsupportedVersion }
        return Set(record.bundleIDs)
    }

    func save(_ bundleIDs: Set<String>) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let data = try JSONEncoder().encode(Record(version: 1, bundleIDs: bundleIDs.sorted()))
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let file = try FileHandle(forWritingTo: url)
        try file.synchronize()
        try file.close()
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let syncResult = Darwin.fsync(descriptor)
        let syncError = errno
        let closeResult = Darwin.close(descriptor)
        guard syncResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: syncError) ?? .EIO) }
        guard closeResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
