import Foundation
import os

/// Bridge to the private MenuBarClientCore.framework (macOS 27): MenuBarAgent renders the menu bar
/// and exposes an XPC restriction "show only these system items and these bundle ids". Its two ObjC
/// classes are resolved at runtime, so a missing framework degrades to `isAvailable == false`.
@objc private protocol AssessmentModeAssertion {
    @objc(activateWithConfiguration:completionHandler:)
    func activate(with configuration: AnyObject, completionHandler: @escaping (NSError?) -> Void)
    func invalidate()
}

enum MenuBarAgentBridgeError: LocalizedError {
    case unavailable
    case configurationFailed
    case activation(NSError)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "MenuBarClientCore.framework is missing or changed"
        case .configurationFailed: return "could not build the allow-list configuration"
        case .activation(let error): return "MenuBarAgent refused: \(error.localizedDescription)"
        }
    }
}

protocol HidingEngine: AnyObject {
    var isAvailable: Bool { get }
    /// The allow list currently in force, nil while nothing is restricted.
    var appliedAllowList: [String]? { get }
    /// `completion` runs at most once, on the main thread, and never for a request
    /// superseded by a later `restrict` or `release`.
    func restrict(allowedBundleIDs: [String], completion: @escaping (Error?) -> Void)
    func release()
}

final class MenuBarAgentBridge: HidingEngine {
    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore"
    private static let configurationInit = NSSelectorFromString("initWithAllowedSystemItems:allowedBundleIdentifiers:")

    private let log = Log.bridge
    private let classes: (assertion: NSObject.Type, configuration: NSObject.Type)?
    private var active: (assertion: AssessmentModeAssertion, allowList: [String])?
    private var pending: AssessmentModeAssertion?

    init() {
        // Every selector must exist: an unchecked message send would crash instead of degrading.
        guard dlopen(Self.frameworkPath, RTLD_NOW) != nil,
            let assertion = NSClassFromString("MBAssessmentModeAssertion") as? NSObject.Type,
            let configuration = NSClassFromString("MBAssessmentModeConfiguration") as? NSObject.Type,
            assertion.instancesRespond(to: #selector(AssessmentModeAssertion.activate(with:completionHandler:))),
            assertion.instancesRespond(to: #selector(AssessmentModeAssertion.invalidate)),
            configuration.instancesRespond(to: Self.configurationInit)
        else {
            log.error("MenuBarClientCore is missing or its MBAssessmentMode classes changed")
            classes = nil
            return
        }
        classes = (assertion, configuration)
    }

    var isAvailable: Bool { classes != nil }
    var appliedAllowList: [String]? { active?.allowList }

    func restrict(allowedBundleIDs: [String], completion: @escaping (Error?) -> Void) {
        guard let classes else {
            completion(MenuBarAgentBridgeError.unavailable)
            return
        }
        guard let configuration = Self.makeConfiguration(classes.configuration, bundleIDs: allowedBundleIDs) else {
            completion(MenuBarAgentBridgeError.configurationFailed)
            return
        }

        pending?.invalidate()
        let assertion = unsafeBitCast(classes.assertion.init(), to: AssessmentModeAssertion.self)
        pending = assertion
        log.error("activating restriction, allowed bundle ids: \(allowedBundleIDs.count)")
        assertion.activate(with: configuration) { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.pending === assertion else { return }
                self.pending = nil
                if let error {
                    // Keep the previous restriction: a failed replacement must not unhide anything.
                    assertion.invalidate()
                    self.log.error("activation failed: \(error.localizedDescription)")
                    completion(MenuBarAgentBridgeError.activation(error))
                } else {
                    // The old assertion goes only once the new one is in place, so nothing flashes.
                    self.active?.assertion.invalidate()
                    self.active = (assertion, allowedBundleIDs)
                    completion(nil)
                }
            }
        }
    }

    func release() {
        guard active != nil || pending != nil else { return }
        log.error("releasing restriction")
        pending?.invalidate()
        pending = nil
        active?.assertion.invalidate()
        active = nil
    }

    /// `[[MBAssessmentModeConfiguration alloc] initWithAllowedSystemItems:allowedBundleIdentifiers:]`
    private static func makeConfiguration(_ cls: NSObject.Type, bundleIDs: [String]) -> AnyObject? {
        // alloc returns +1 which init consumes; init returns +1 that we own, so take it retained.
        let allocated = (cls as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue()
        let systemItems = SystemItems.allowedIdentifiers as NSArray
        return allocated?.perform(configurationInit, with: systemItems, with: bundleIDs as NSArray)?.takeRetainedValue()
    }
}
