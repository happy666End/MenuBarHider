import Foundation

/// MenuBarAgent honours the allow list only for apps under /Applications, ours included.
enum AppLocation {
    static let applicationsFolder = URL(fileURLWithPath: "/Applications", isDirectory: true)

    static func isInApplications(_ bundleURL: URL) -> Bool {
        bundleURL.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(applicationsFolder.path + "/")
    }

    static func install(_ source: URL, into folder: URL, fileManager: FileManager = .default) throws -> URL {
        let destination = folder.appendingPathComponent(source.lastPathComponent, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        do {
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            // Across volumes the move copies first and fails only at deleting a read-only source.
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: source, to: destination)
        }
        return destination
    }
}
