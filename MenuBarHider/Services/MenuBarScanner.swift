import AppKit
import ApplicationServices

/// Reads third-party menu bar item positions through Accessibility.
protocol MenuBarItemSource {
    var isTrusted: Bool { get }
    func scan() -> [MenuBarItemPosition]
}

final class MenuBarScanner: MenuBarItemSource {
    /// Per-process cap for Accessibility calls: an unresponsive app must not stall the scan.
    private static let messagingTimeout: Float = 0.2

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
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        Log.controller.error("AX scan took \(elapsed) ms, apps: \(candidates.count), items: \(result.count)")
        return result
    }

    private static func positions(pid: pid_t, bundleID: String) -> [MenuBarItemPosition] {
        guard let bar = AXAttributes.extrasMenuBar(pid: pid, timeout: messagingTimeout) else { return [] }
        return AXAttributes.elements(bar, kAXChildrenAttribute).compactMap { child in
            AXAttributes.point(child, kAXPositionAttribute).map { MenuBarItemPosition(bundleID: bundleID, x: $0.x) }
        }
    }
}
