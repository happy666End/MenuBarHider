import CoreFoundation
import Darwin
import Foundation

protocol TrackedApplicationsStore {
    func read() throws -> Data
    func write(_ data: Data) throws
}

struct SystemTrackedApplicationsStore: TrackedApplicationsStore {
    enum Failure: LocalizedError {
        case unavailable
        case unreadable
        case synchronizationFailed

        var errorDescription: String? {
            switch self {
            case .unavailable: "The container-aware macOS preference functions are unavailable."
            case .unreadable: "The tracked applications preference is missing or is not Data."
            case .synchronizationFailed: "The tracked applications preference could not be synchronized."
            }
        }
    }

    struct Functions {
        var copy: (CFString, CFString, CFString, CFString, CFString) -> Unmanaged<CFPropertyList>?
        var set: (CFString, CFPropertyList?, CFString, CFString, CFString, CFString) -> Void
        var synchronize: (CFString, CFString, CFString, CFString) -> Bool
    }

    private static let key = "trackedApplications" as CFString
    private static let application = "group.com.apple.controlcenter" as CFString
    private let functions: () throws -> Functions

    private var container: CFString {
        (NSHomeDirectory() + "/Library/Group Containers/group.com.apple.controlcenter") as CFString
    }

    init() {
        self.functions = { try Self.systemFunctions.get() }
    }

    init(functions: @escaping () throws -> Functions) {
        self.functions = functions
    }

    func read() throws -> Data {
        let functions = try functions()
        try synchronize(functions)
        guard
            let value = functions.copy(
                Self.key, Self.application, kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost, container)?.takeRetainedValue(),
            CFGetTypeID(value) == CFDataGetTypeID(), let data = value as? Data
        else {
            throw Failure.unreadable
        }
        return data
    }

    func write(_ data: Data) throws {
        let functions = try functions()
        functions.set(
            Self.key, data as CFData, Self.application, kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost, container)
        try synchronize(functions)
    }

    private func synchronize(_ functions: Functions) throws {
        guard functions.synchronize(Self.application, kCFPreferencesCurrentUser, kCFPreferencesAnyHost, container)
        else {
            throw Failure.synchronizationFailed
        }
    }

    private static let systemFunctions: Result<Functions, Error> = Result {
        typealias Copy = @convention(c) (CFString, CFString, CFString, CFString, CFString) -> Unmanaged<CFPropertyList>?
        typealias SetValue = @convention(c) (CFString, CFPropertyList?, CFString, CFString, CFString, CFString) -> Void
        typealias Synchronize = @convention(c) (CFString, CFString, CFString, CFString) -> Bool

        guard let handle = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_NOW) else {
            throw Failure.unavailable
        }
        guard let copySymbol = dlsym(handle, "_CFPreferencesCopyValueWithContainer"),
            let setSymbol = dlsym(handle, "_CFPreferencesSetValueWithContainer"),
            let synchronizeSymbol = dlsym(handle, "_CFPreferencesSynchronizeWithContainer")
        else {
            dlclose(handle)
            throw Failure.unavailable
        }
        // The function pointers require the framework handle to remain open.
        let copy = unsafeBitCast(copySymbol, to: Copy.self)
        let set = unsafeBitCast(setSymbol, to: SetValue.self)
        let synchronize = unsafeBitCast(synchronizeSymbol, to: Synchronize.self)
        return Functions(
            copy: { copy($0, $1, $2, $3, $4) },
            set: { set($0, $1, $2, $3, $4, $5) },
            synchronize: { synchronize($0, $1, $2, $3) })
    }
}
