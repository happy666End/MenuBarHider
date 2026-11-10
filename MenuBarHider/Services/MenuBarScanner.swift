import AppKit
import ApplicationServices

/// Reads menu bar item positions through Accessibility.
protocol MenuBarItemSource {
    var isTrusted: Bool { get }
    func scan() -> MenuBarScan
}

final class MenuBarScanner: MenuBarItemSource {
    struct Application {
        var pid: pid_t
        var bundleID: String
        var activationPolicy: NSApplication.ActivationPolicy
    }

    /// Per-process cap for Accessibility calls: an unresponsive app must not stall the scan.
    private static let messagingTimeout: Float = 0.2

    private let extras: MenuExtraHost
    private let applications: () -> [Application]
    private let reader: AXAttributeReader
    private let systemItems: () -> MenuBarScan

    init(
        extras: MenuExtraHost,
        applications: @escaping () -> [Application] = MenuBarScanner.runningApplications,
        reader: AXAttributeReader = AXAttributeReader(),
        systemItems: @escaping () -> MenuBarScan = MenuBarScanner.systemItems
    ) {
        self.extras = extras
        self.applications = applications
        self.reader = reader
        self.systemItems = systemItems
    }

    var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func scan() -> MenuBarScan {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let started = Date()
        // Shared Apple hosts have separate scanners; other Apple agents own ordinary status items.
        let candidates = applications().filter { app in
            app.activationPolicy != .prohibited && app.pid != ownPID
                && !SystemItems.alwaysAllowedBundleIDs.contains(app.bundleID)
        }
        // Each AX round trip costs ~35 ms; AXUIElement calls are safe to make from any thread.
        let lock = NSLock()
        var result = MenuBarScan(positions: [])
        DispatchQueue.concurrentPerform(iterations: candidates.count) { index in
            let app = candidates[index]
            let observation = Self.positions(pid: app.pid, bundleID: app.bundleID, reader: reader)
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
        let systemScan = systemItems()
        result.positions.append(contentsOf: systemScan.positions)
        result.failedBundleIDs.formUnion(systemScan.failedBundleIDs)
        // A bundle ID can identify multiple running processes.
        result.positions.removeAll { result.failedBundleIDs.contains($0.bundleID) }
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        Log.controller.error("AX scan took \(elapsed) ms, apps: \(candidates.count), items: \(result.positions.count)")
        return result
    }

    static func runningApplications() -> [Application] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundleID = app.bundleIdentifier else { return nil }
            return Application(pid: app.processIdentifier, bundleID: bundleID, activationPolicy: app.activationPolicy)
        }
    }

    static func systemItems() -> MenuBarScan {
        systemItemPositions(
            pid: NSRunningApplication.runningApplications(
                withBundleIdentifier: SystemItems.menuBarAgentBundleID
            ).first?.processIdentifier)
    }

    static func systemItemPositions(pid: pid_t?, reader: AXAttributeReader = AXAttributeReader()) -> MenuBarScan {
        let failed = MenuBarScan(positions: [], failedBundleIDs: SystemItems.selectionIDs)
        guard let pid else { return failed }
        do {
            guard let bar = try reader.extrasMenuBar(pid: pid, timeout: messagingTimeout) else { return failed }
            var result = MenuBarScan(positions: [])
            var unidentified = false
            for child in try reader.elements(bar, kAXChildrenAttribute) {
                let role = try reader.optionalString(child, kAXRoleAttribute)
                let items = role == kAXGroupRole ? try reader.elements(child, kAXChildrenAttribute) : [child]
                if items.isEmpty { unidentified = true }
                for item in items {
                    guard let identifier = try reader.optionalString(item, kAXIdentifierAttribute),
                        SystemItems.controls.contains(where: { $0.accessibilityIdentifier == identifier })
                    else {
                        unidentified = true
                        continue
                    }
                    if let selection = SystemItems.selectionID(forAccessibilityIdentifier: identifier) {
                        result.positions.append(
                            .init(
                                bundleID: selection, x: try reader.point(item, kAXPositionAttribute).x))
                    }
                }
            }
            let grouped = Dictionary(grouping: result.positions, by: \.bundleID)
            let ambiguous = Set(grouped.filter { $0.value.count > 1 }.keys)
            result.failedBundleIDs = ambiguous
            if unidentified {
                result.failedBundleIDs.formUnion(SystemItems.selectionIDs.subtracting(grouped.keys))
            }
            result.positions.removeAll { result.failedBundleIDs.contains($0.bundleID) }
            return result
        } catch { return failed }
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
