import Foundation

final class HidingEngineRouter: HidingEngine {
    private let settings: Settings
    private let assessment: HidingEngine
    private let native: NativeHidingEngine
    private var recoveryError: Error?
    private var selectionError: Error?
    private(set) var method: HidingMethod

    init(settings: Settings, assessment: HidingEngine, native: NativeHidingEngine) {
        self.settings = settings
        self.assessment = assessment
        self.native = native
        method = settings.hidingMethod
        do { try native.recover() } catch { recoveryError = error }
    }

    private var current: HidingEngine { method == .systemSettings ? native : assessment }
    var isAvailable: Bool { recoveryError == nil && current.isAvailable }
    var appliedAllowList: [String]? { current.appliedAllowList }
    var requestedAllowList: [String]? { current.requestedAllowList }
    var requiresClockHover: Bool { current.requiresClockHover }
    var lastOperationError: Error? { recoveryError ?? selectionError ?? current.lastOperationError }

    func updateObservedBundleIDs(_ bundleIDs: Set<String>, failedBundleIDs: Set<String> = []) {
        native.updateObservedBundleIDs(bundleIDs, failedBundleIDs: failedBundleIDs)
    }

    func select(_ method: HidingMethod) throws {
        do {
            current.release()
            if let error = current.lastOperationError {
                recoveryError = error
                throw error
            }
            try native.recover()
            recoveryError = nil
            if method == .systemSettings { try native.validateAvailability() }
            self.method = method
            settings.hidingMethod = method
            selectionError = nil
        } catch {
            selectionError = error
            throw error
        }
    }

    func restrict(allowedBundleIDs: [String], completion: @escaping (Error?) -> Void) {
        guard isAvailable else {
            completion(lastOperationError ?? NativeHidingFailure.unavailable)
            return
        }
        selectionError = nil
        current.restrict(allowedBundleIDs: allowedBundleIDs, completion: completion)
    }

    func release() {
        current.release()
        if let error = current.lastOperationError {
            recoveryError = error
            return
        }
        do {
            try native.recover()
            recoveryError = nil
            selectionError = nil
        } catch {
            recoveryError = error
        }
    }
}
