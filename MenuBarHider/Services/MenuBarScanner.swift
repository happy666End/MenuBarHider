import AppKit
import ApplicationServices

/// Reads menu bar item positions through Accessibility.
protocol MenuBarItemSource {
    var isTrusted: Bool { get }
    func scan() -> [MenuBarItemPosition]
}

final class MenuBarScanner: MenuBarItemSource {
    /// Per-process cap for Accessibility calls: an unresponsive app must not stall the scan.
    private static let messagingTimeout: Float = 0.2

    private let extras: MenuExtraHost

    init(extras: MenuExtraHost) {
        self.extras = extras
    }

    var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func scan() -> [MenuBarItemPosition] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let started = Date()
        // Daemons and Apple agents own nothing that can be hidden; skipping them keeps the scan short.
        let candidates: [(pid: pid_t, bundleID: String)] = NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy != .prohibited, app.processIdentifier != ownPID,
                let bundleID = app.bundleIdentifier, !bundleID.hasPrefix("com.apple."),
                !SystemItems.alwaysAllowedBundleIDs.contains(bundleID)
            else { return nil }
            return (app.processIdentifier, bundleID)
        }
        // Each AX round trip costs ~35 ms; AXUIElement calls are safe to make from any thread.
        let lock = NSLock()
        var result: [MenuBarItemPosition] = []
        DispatchQueue.concurrentPerform(iterations: candidates.count) { index in
            let (pid, bundleID) = candidates[index]
            let positions = Self.positions(pid: pid, bundleID: bundleID)
            guard !positions.isEmpty else { return }
            lock.lock()
            result.append(contentsOf: positions)
            lock.unlock()
        }
        result.append(contentsOf: menuExtraPositions())
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        Log.controller.error("AX scan took \(elapsed) ms, apps: \(candidates.count), items: \(result.count)")
        return result
    }

    private func menuExtraPositions() -> [MenuBarItemPosition] {
        guard
            let server = NSRunningApplication.runningApplications(
                withBundleIdentifier: SystemItems.systemUIServerBundleID
            ).first,
            let bar = AXAttributes.extrasMenuBar(pid: server.processIdentifier, timeout: Self.messagingTimeout)
        else { return [] }
        let children = AXAttributes.elements(bar, kAXChildrenAttribute)
        let xs = children.compactMap { AXAttributes.point($0, kAXPositionAttribute)?.x }
        let loaded = extras.loadedExtraIDs()
        guard xs.count == children.count, xs.count == loaded.count else {
            Log.controller.error("menu extras skipped: \(children.count) items, \(loaded.count) loaded")
            return []
        }
        return MenuExtras.positions(itemXs: xs, loadedIDs: loaded)
    }

    private static func positions(pid: pid_t, bundleID: String) -> [MenuBarItemPosition] {
        guard let bar = AXAttributes.extrasMenuBar(pid: pid, timeout: messagingTimeout) else { return [] }
        return AXAttributes.elements(bar, kAXChildrenAttribute).compactMap { child in
            AXAttributes.point(child, kAXPositionAttribute).map { MenuBarItemPosition(bundleID: bundleID, x: $0.x) }
        }
    }
}
