import Foundation

protocol MenuExtraHost {
    func loadedExtraIDs() -> [String]
    func remove(_ id: String) -> Bool
    func restore(_ id: String) -> Bool
}

final class SystemUIServerExtras: MenuExtraHost {
    private typealias Handle = UnsafeMutableRawPointer
    private typealias GetFunction = @convention(c) (CFString, UnsafeMutablePointer<Handle?>) -> OSStatus
    private typealias AddFunction = @convention(c) (CFURL, Int32, Int32, Int32, Int32, Int32) -> OSStatus
    private typealias RemoveFunction = @convention(c) (Handle, Int32) -> OSStatus

    private struct Functions {
        let get: GetFunction
        let add: AddFunction
        let remove: RemoveFunction
    }

    private static let frameworkPath = "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
    private static let extrasDirectory = URL(fileURLWithPath: "/System/Library/CoreServices/Menu Extras")

    private let functions: Functions?
    private let bundles: [String: URL]

    init() {
        bundles = Self.extraBundles()
        guard let framework = dlopen(Self.frameworkPath, RTLD_NOW),
            let get = dlsym(framework, "CoreMenuExtraGetMenuExtra"),
            let add = dlsym(framework, "CoreMenuExtraAddMenuExtra"),
            let remove = dlsym(framework, "CoreMenuExtraRemoveMenuExtra")
        else {
            Log.bridge.error("CoreMenuExtra functions are missing, menu extras stay visible")
            functions = nil
            return
        }
        functions = Functions(
            get: unsafeBitCast(get, to: GetFunction.self),
            add: unsafeBitCast(add, to: AddFunction.self),
            remove: unsafeBitCast(remove, to: RemoveFunction.self))
    }

    func loadedExtraIDs() -> [String] {
        MenuExtras.loadOrder(handles: Dictionary(uniqueKeysWithValues: bundles.keys.map { ($0, handle($0)) }))
    }

    func remove(_ id: String) -> Bool {
        let value = handle(id)
        guard let functions, value > 0, let extra = Handle(bitPattern: Int(value)) else { return false }
        let status = functions.remove(extra, 0)
        Log.bridge.error("unload \(id, privacy: .public): \(status)")
        return status == noErr
    }

    func restore(_ id: String) -> Bool {
        guard let functions, let url = bundles[id] else { return false }
        let status = functions.add(url as CFURL, 0, 0, 0, 0, 0)
        Log.bridge.error("load \(id, privacy: .public): \(status)")
        return status == noErr
    }

    /// The call fills only the low 32 bits of the out pointer.
    private func handle(_ id: String) -> Int32 {
        var extra: Handle?
        guard let functions, functions.get(id as CFString, &extra) == noErr else { return 0 }
        return Int32(truncatingIfNeeded: Int(bitPattern: extra))
    }

    private static func extraBundles() -> [String: URL] {
        let urls =
            (try? FileManager.default.contentsOfDirectory(at: extrasDirectory, includingPropertiesForKeys: nil)) ?? []
        return Dictionary(
            urls.filter { $0.pathExtension == "menu" }.compactMap { url in
                Bundle(url: url)?.bundleIdentifier.map { ($0, url) }
            },
            uniquingKeysWith: { first, _ in first })
    }
}
