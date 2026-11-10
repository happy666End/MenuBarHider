import Darwin
import Foundation

final class ApplicationInstanceLock {
    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    deinit { Darwin.close(descriptor) }

    static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/MenuBarHider/instance.lock")
    }

    static func acquire(url: URL = ApplicationInstanceLock.defaultURL) throws -> ApplicationInstanceLock? {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directoryDescriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryDescriptor >= 0 else { throw posixError() }
        defer { Darwin.close(directoryDescriptor) }
        guard Darwin.fchmod(directoryDescriptor, 0o700) == 0 else { throw posixError() }

        let descriptor = Darwin.openat(
            directoryDescriptor, url.lastPathComponent, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        var acquired = false
        defer { if !acquired { Darwin.close(descriptor) } }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else { throw posixError() }
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == geteuid(), metadata.st_nlink == 1 else {
            throw POSIXError(.EINVAL)
        }
        guard Darwin.fchmod(descriptor, 0o600) == 0 else { throw posixError() }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { return nil }
            throw posixError()
        }
        acquired = true
        return ApplicationInstanceLock(descriptor: descriptor)
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
