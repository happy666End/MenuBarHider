import AppKit
import ApplicationServices

/// Reads menu bar item positions through Accessibility.
protocol MenuBarItemSource {
    var isTrusted: Bool { get }
    func scan() -> MenuBarScan
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

    func scan() -> MenuBarScan {
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
        var result = MenuBarScan(positions: [])
        DispatchQueue.concurrentPerform(iterations: candidates.count) { index in
            let (pid, bundleID) = candidates[index]
            let observation = Self.positions(pid: pid, bundleID: bundleID)
            lock.lock()
            result.positions.append(contentsOf: observation.positions)
            result.failedBundleIDs.formUnion(observation.failedBundleIDs)
            lock.unlock()
        }
        let extraScan = Self.menuExtraPositions(
            pid: NSRunningApplication.runningApplications(
                withBundleIdentifier: SystemItems.systemUIServerBundleID
            ).first?.processIdentifier,
            loadedIDs: extras.loadedExtraIDs())
        result.positions.append(contentsOf: extraScan.positions)
        result.failedBundleIDs.formUnion(extraScan.failedBundleIDs)
        // A bundle ID can identify multiple running processes.
        result.positions.removeAll { result.failedBundleIDs.contains($0.bundleID) }
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        Log.controller.error("AX scan took \(elapsed) ms, apps: \(candidates.count), items: \(result.positions.count)")
        return result
    }

    static func menuExtraPositions(
        pid: pid_t?, loadedIDs: [String], reader: AXAttributeReader = AXAttributeReader()
    ) -> MenuBarScan {
        let failed = MenuBarScan(positions: [], failedBundleIDs: Set(loadedIDs))
        guard let pid else { return failed }
        do {
            guard let bar = try reader.extrasMenuBar(pid: pid, timeout: messagingTimeout) else { return failed }
            let children = try reader.elements(bar, kAXChildrenAttribute)
            let xs = try children.map { try reader.point($0, kAXPositionAttribute).x }
            guard xs.count == loadedIDs.count else {
                Log.controller.error("menu extras skipped: \(children.count) items, \(loadedIDs.count) loaded")
                return failed
            }
            return MenuBarScan(positions: MenuExtras.positions(itemXs: xs, loadedIDs: loadedIDs))
        } catch {
            return failed
        }
    }

    static func positions(
        pid: pid_t, bundleID: String, reader: AXAttributeReader = AXAttributeReader()
    ) -> MenuBarScan {
        do {
            guard let bar = try reader.extrasMenuBar(pid: pid, timeout: messagingTimeout) else {
                return MenuBarScan(positions: [])
            }
            let children = try reader.elements(bar, kAXChildrenAttribute)
            let positions = try children.map { child in
                MenuBarItemPosition(bundleID: bundleID, x: try reader.point(child, kAXPositionAttribute).x)
            }
            return MenuBarScan(positions: positions)
        } catch {
            return MenuBarScan(positions: [], failedBundleIDs: [bundleID])
        }
    }
}
