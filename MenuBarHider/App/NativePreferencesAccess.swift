import AppKit

@MainActor
final class NativePreferencesAccess {
    enum Failure: LocalizedError {
        case wrongFolder
        var errorDescription: String? { "Choose only the group.com.apple.controlcenter folder shown." }
    }
    private static let bookmarkKey = "nativeMenuBarSettingsBookmark"
    private let defaults: UserDefaults
    private var accessedURL: URL?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.bookmarkKey) else { return }
        do {
            var stale = false
            let url = try URL(
                resolvingBookmarkData: data, options: [.withSecurityScope],
                relativeTo: nil, bookmarkDataIsStale: &stale)
            guard url.standardizedFileURL == Self.containerURL.standardizedFileURL else { return }
            if url.startAccessingSecurityScopedResource() { accessedURL = url }
            if stale {
                defaults.set(try url.bookmarkData(options: [.withSecurityScope]), forKey: Self.bookmarkKey)
            }
        } catch {
            Log.ui.error("Menu Bar settings access bookmark could not be restored")
        }
    }

    static var containerURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
            "Library/Group Containers/group.com.apple.controlcenter"
        )
    }

    func requestAccess() throws -> Bool {
        let panel = NSOpenPanel()
        panel.title = "Allow Access to Menu Bar Settings"
        panel.message = "Allow access only to the Control Center settings folder. Full Disk Access is not required."
        panel.prompt = "Allow Access"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = Self.containerURL.deletingLastPathComponent()
        panel.nameFieldStringValue = Self.containerURL.lastPathComponent
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        guard url.standardizedFileURL == Self.containerURL.standardizedFileURL else {
            throw Failure.wrongFolder
        }
        let bookmark = try url.bookmarkData(options: [.withSecurityScope])
        let accessing = url.startAccessingSecurityScopedResource()
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = accessing ? url : nil
        defaults.set(bookmark, forKey: Self.bookmarkKey)
        return true
    }
}
