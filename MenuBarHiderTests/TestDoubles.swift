import Foundation

@testable import MenuBarHider

final class FakeEngine: HidingEngine {
    var isAvailable = true
    var appliedAllowList: [String]?
    var restrictions: [[String]] = []
    var releases = 0
    var nextError: Error?

    func restrict(allowedBundleIDs: [String], completion: @escaping (Error?) -> Void) {
        restrictions.append(allowedBundleIDs)
        if nextError == nil { appliedAllowList = allowedBundleIDs }
        completion(nextError)
    }

    func release() {
        guard appliedAllowList != nil else { return }
        appliedAllowList = nil
        releases += 1
    }
}

final class FakeItems: MenuBarItemSource {
    var isTrusted = true
    var positions: [MenuBarItemPosition] = []
    func scan() -> [MenuBarItemPosition] { positions }
}

final class FakeRunning: RunningAppsSource {
    var bundleIDs: [String] = []
}

final class FakeExtras: MenuExtraHost {
    var loaded: [String] = []
    var removals: [String] = []
    var restorations: [String] = []
    var failRestore = false

    func loadedExtraIDs() -> [String] { loaded }

    func remove(_ id: String) -> Bool {
        guard let index = loaded.firstIndex(of: id) else { return false }
        loaded.remove(at: index)
        removals.append(id)
        return true
    }

    func restore(_ id: String) -> Bool {
        restorations.append(id)
        guard !failRestore else { return false }
        loaded.append(id)
        return true
    }
}

final class ManualScheduler: TimerScheduler {
    final class Token: Cancellable {
        var cancelled = false
        func cancel() { cancelled = true }
    }
    struct Entry {
        let seconds: TimeInterval
        let block: () -> Void
        let token: Token
    }
    var pending: [Entry] = []
    var live: [Entry] { pending.filter { !$0.token.cancelled } }

    func schedule(after seconds: TimeInterval, _ block: @escaping () -> Void) -> Cancellable {
        let token = Token()
        pending.append(Entry(seconds: seconds, block: block, token: token))
        return token
    }

    /// Runs every live timer once; timers armed by those blocks wait for the next call.
    func fireAll() {
        let entries = live
        pending = []
        for entry in entries { entry.block() }
    }
}

struct Boom: Error {}
