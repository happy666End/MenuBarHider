import AppKit

enum NativeHidingFailure: LocalizedError {
    case unavailable
    case unregisteredApplications(Int)
    case verificationFailed
    case sharedVisibleOwner

    var errorDescription: String? {
        switch self {
        case .unavailable: return "System Settings hiding requires macOS 27 and access to Menu Bar settings."
        case .unregisteredApplications(let count):
            return "\(count) selected application(s) are not registered in Menu Bar settings yet."
        case .verificationFailed: return "The menu bar visibility change could not be verified. Use Show to restore it."
        case .sharedVisibleOwner:
            return "A selected icon shares its system switch with a visible icon. Use Compatibility for this layout."
        }
    }
}

final class NativeHidingEngine: HidingEngine {
    private(set) var appliedAllowList: [String]?
    private(set) var lastOperationError: Error?
    var requestedAllowList: [String]? { lastOperationError == nil ? appliedAllowList : nil }
    private let store: TrackedApplicationsStore
    private let journal: NativeVisibilityJournal
    private let runningApps: RunningAppsSource
    private let parentBundleIDs: (String) -> [String]
    private var observedBundleIDs: Set<String>?
    private var failedBundleIDs: Set<String> = []
    var requiresClockHover: Bool { false }
    var isAvailable: Bool {
        do {
            try validateAvailability()
            return true
        } catch {
            lastOperationError = error
            return false
        }
    }

    init(
        store: TrackedApplicationsStore, journal: NativeVisibilityJournal, runningApps: RunningAppsSource,
        parentBundleIDs: @escaping (String) -> [String] = NativeHidingEngine.parentBundleIdentifiers
    ) {
        self.store = store
        self.journal = journal
        self.runningApps = runningApps
        self.parentBundleIDs = parentBundleIDs
    }

    func validateAvailability() throws {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 else {
            throw NativeHidingFailure.unavailable
        }
        _ = try TrackedApplicationsDocument(data: store.read()).states()
    }

    func updateObservedBundleIDs(_ bundleIDs: Set<String>, failedBundleIDs: Set<String> = []) {
        observedBundleIDs = bundleIDs
        self.failedBundleIDs = failedBundleIDs
    }

    func validate(_ restriction: MenuBarRestriction) throws {
        guard restriction.hiddenSystemItems.isEmpty else { throw HidingRestrictionFailure.unsupportedAppleItems }
        let document = try TrackedApplicationsDocument(data: store.read())
        _ = try desiredOwners(allowedBundleIDs: restriction.allowedBundleIDs, document: document)
    }

    func recover() throws {
        do {
            let owned = try journal.load()
            guard !owned.isEmpty else {
                appliedAllowList = nil
                lastOperationError = nil
                return
            }
            let document = try TrackedApplicationsDocument(data: store.read())
            let states = try document.states()
            let restore = Dictionary(
                uniqueKeysWithValues: owned.compactMap { id in
                    states[id] == false ? (id, true) : nil
                })
            if !restore.isEmpty {
                try store.write(document.settingAllowed(restore))
                let verified = try TrackedApplicationsDocument(data: store.read()).states()
                guard restore.keys.allSatisfy({ verified[$0] == true }) else {
                    throw NativeHidingFailure.verificationFailed
                }
            }
            try journal.save([])
            appliedAllowList = nil
            lastOperationError = nil
        } catch {
            lastOperationError = error
            throw error
        }
    }

    func release() {
        do { try recover() } catch { lastOperationError = error }
    }

    func restrict(allowedBundleIDs: [String], completion: @escaping (Error?) -> Void) {
        guard allowedBundleIDs != appliedAllowList || lastOperationError != nil else {
            completion(nil)
            return
        }
        let started = Date()
        do {
            try apply(allowedBundleIDs)
            appliedAllowList = allowedBundleIDs
            lastOperationError = nil
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            Log.bridge.error("System Settings visibility applied in \(elapsed) ms")
            completion(nil)
        } catch {
            lastOperationError = error
            completion(error)
        }
    }

    private func apply(_ allowedBundleIDs: [String]) throws {
        let document = try TrackedApplicationsDocument(data: store.read())
        let states = try document.states()
        let desiredOwners = try desiredOwners(allowedBundleIDs: allowedBundleIDs, document: document)
        let owned = try journal.load()
        let newOwnership = desiredOwners.filter { states[$0] == true }
        let nextOwnership = newOwnership.union(owned.intersection(desiredOwners))
        var changes: [String: Bool] = [:]
        for id in owned.subtracting(desiredOwners) where states[id] == false { changes[id] = true }
        for id in desiredOwners where states[id] == true { changes[id] = false }
        let data = changes.isEmpty ? nil : try document.settingAllowed(changes)

        // Synchronization can fail after the system preference has already changed.
        let pendingRecovery = owned.union(newOwnership)
        if pendingRecovery != owned { try journal.save(pendingRecovery) }
        if let data {
            try store.write(data)
            let verified = try TrackedApplicationsDocument(data: store.read()).states()
            guard changes.allSatisfy({ verified[$0.key] == $0.value }) else {
                throw NativeHidingFailure.verificationFailed
            }
        }
        if pendingRecovery != nextOwnership { try journal.save(nextOwnership) }
    }

    private func desiredOwners(
        allowedBundleIDs: [String], document: TrackedApplicationsDocument
    ) throws -> Set<String> {
        let hidden = Set(runningApps.bundleIDs).subtracting(allowedBundleIDs)
        let desiredOwners = try owners(for: hidden, in: document)
        let running = Set(runningApps.bundleIDs)
        let visibleItems = (observedBundleIDs ?? running).union(failedBundleIDs.intersection(running))
            .intersection(allowedBundleIDs)
        let visibleOwners = try owners(for: visibleItems, in: document, requireRegistered: false)
        guard desiredOwners.isDisjoint(with: visibleOwners) else {
            throw NativeHidingFailure.sharedVisibleOwner
        }
        return desiredOwners
    }

    private func owners(
        for bundleIDs: Set<String>, in document: TrackedApplicationsDocument, requireRegistered: Bool = true
    ) throws -> Set<String> {
        var result: Set<String> = []
        var missing = 0
        for id in bundleIDs {
            var owner: String?
            for candidate in [id] + parentBundleIDs(id) {
                if let match = try document.owner(for: candidate) {
                    owner = match
                    break
                }
            }
            if let owner {
                result.insert(owner)
            } else if requireRegistered && id.hasPrefix("com.apple.") {
                throw HidingRestrictionFailure.unsupportedAppleItems
            } else {
                missing += 1
            }
        }
        guard !requireRegistered || missing == 0 else {
            throw NativeHidingFailure.unregisteredApplications(missing)
        }
        return result
    }

    private static func parentBundleIdentifiers(for id: String) -> [String] {
        guard let application = NSRunningApplication.runningApplications(withBundleIdentifier: id).first,
            var url = application.bundleURL
        else { return [] }
        var result: [String] = []
        while url.path != "/" {
            url.deleteLastPathComponent()
            if url.pathExtension == "app", let bundleID = Bundle(url: url)?.bundleIdentifier {
                result.append(bundleID)
            }
        }
        return result
    }
}
