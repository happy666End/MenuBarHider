import AppKit
import ServiceManagement

/// The two separator icons in the menu bar and the context menu behind them.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private static let repositoryURL = URL(string: "https://github.com/happy666End/MenuBarHider")!
    private static let autoHideChoices: [(seconds: Int, title: String)] = [
        (0, "Never"), (5, "5 seconds"), (10, "10 seconds"), (30, "30 seconds"), (60, "1 minute"),
    ]

    /// The `»` separator: everything left of it (down to `|`) gets hidden.
    private let statusItem: NSStatusItem
    /// The `|` separator: items left of it stay visible; on screen only while expanded.
    private let leftSeparator: NSStatusItem
    private let menu = NSMenu()
    private var controller: HidingController?
    private var nativeAccess: NativePreferencesAccess?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        leftSeparator = NSStatusBar.system.statusItem(withLength: 12)
        super.init()
        menu.delegate = self
        configure(statusItem, autosaveName: "MenuBarHiderSeparator")
        configure(leftSeparator, autosaveName: "MenuBarHiderLeftSeparator")
        leftSeparator.button?.image = Self.symbol("poweron", description: "MenuBarHider boundary")
        updateIcon(state: .shown)
    }

    func attach(_ controller: HidingController, nativeAccess: NativePreferencesAccess? = nil) {
        self.controller = controller
        self.nativeAccess = nativeAccess
    }

    func stateChanged() {
        if let controller { updateIcon(state: controller.state) }
    }

    var separators: SeparatorPositions {
        SeparatorPositions(
            separatorX: statusItem.button?.window?.frame.minX,
            leftSeparatorX: leftSeparator.isVisible ? leftSeparator.button?.window?.frame.minX : nil
        )
    }

    // MARK: - Status items

    private func configure(_ item: NSStatusItem, autosaveName: String) {
        item.autosaveName = autosaveName
        item.behavior = []
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(buttonClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func updateIcon(state: HidingController.State) {
        let name = state == .hidden ? "chevron.left.2" : "chevron.right.2"
        statusItem.button?.image = Self.symbol(name, description: "MenuBarHider")
        statusItem.button?.setAccessibilityLabel(state == .hidden ? "Show Hidden Items" : "Hide Items")
        statusItem.button?.setAccessibilityHelp(state == .hidden ? "Items are hidden" : "All items are visible")
        leftSeparator.button?.setAccessibilityLabel("Hidden Items Boundary")
        leftSeparator.button?.setAccessibilityHelp("Command-drag to choose which icons remain visible")
        leftSeparator.isVisible = state == .shown
    }

    private static func symbol(_ name: String, description: String? = nil) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
        image?.isTemplate = true
        return image
    }

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isSecondary = event.map { $0.type == .rightMouseUp || $0.modifierFlags.contains(.control) } ?? false
        Log.ui.error("separator clicked, secondary=\(isSecondary), state=\(String(describing: self.controller?.state))")
        if isSecondary {
            let clicked = sender === leftSeparator.button ? leftSeparator : statusItem
            clicked.menu = menu
            clicked.button?.performClick(nil)
            clicked.menu = nil
        } else {
            // The second half of an accidental double click must not toggle straight back.
            guard (event?.clickCount ?? 1) <= 1 else { return }
            controller?.toggle()
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let controller else { return }

        menu.addItem(header(controller))
        if !controller.isInApplications {
            menu.addItem(item("Move to Applications…", symbol: "folder", action: #selector(moveToApplications)))
        } else if !controller.isAccessibilityTrusted {
            menu.addItem(
                item("Open Accessibility Settings…", symbol: "hand.raised", action: #selector(openAccessibility)))
        }
        menu.addItem(.separator())

        if controller.state == .hidden {
            menu.addItem(item("Show Hidden Items", symbol: "eye", action: #selector(toggle)))
        } else {
            menu.addItem(item("Hide Items", symbol: "eye.slash", action: #selector(toggle)))
        }
        let rescan = item("Rescan Layout", symbol: "arrow.clockwise", action: #selector(refresh))
        rescan.toolTip = "Re-read which icons sit between the | and » separators."
        menu.addItem(rescan)
        menu.addItem(.separator())

        menu.addItem(autoHideMenu())
        menu.addItem(hidingMethodMenu())
        if controller.hidingMethod == .systemSettings || controller.lastError != nil {
            menu.addItem(
                item("Restore Menu Bar Visibility", symbol: "arrow.counterclockwise", action: #selector(restore)))
        }
        let login = item("Launch at Login", symbol: nil, action: #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())

        menu.addItem(item("About MenuBarHider", symbol: nil, action: #selector(openRepository)))
        menu.addItem(item("Quit MenuBarHider", symbol: nil, action: #selector(quit), keyEquivalent: "q"))
    }

    private func header(_ controller: HidingController) -> NSMenuItem {
        let status: String
        let symbol: String
        if let error = controller.lastError {
            status = "Error: \(error.localizedDescription)"
            symbol = "exclamationmark.triangle"
        } else if !controller.isEngineAvailable {
            status = "Hiding unavailable on this macOS build"
            symbol = "exclamationmark.triangle"
        } else if !controller.isInApplications {
            status = "Hiding works only from Applications"
            symbol = "exclamationmark.triangle"
        } else if !controller.isAccessibilityTrusted {
            status = "Accessibility permission required"
            symbol = "exclamationmark.triangle"
        } else if controller.state == .hidden {
            let count = controller.hiddenSet.count
            status = count == 1 ? "Hiding 1 app" : "Hiding \(count) apps"
            symbol = "eye.slash"
        } else {
            status = "All items visible"
            symbol = "eye"
        }
        let line = item(status, symbol: symbol, action: nil)
        line.isEnabled = false
        return line
    }

    private func autoHideMenu() -> NSMenuItem {
        let parent = item("Auto-hide After", symbol: "timer", action: nil)
        let submenu = NSMenu()
        for choice in Self.autoHideChoices {
            let entry = item(choice.title, symbol: nil, action: #selector(setAutoHide(_:)))
            entry.tag = choice.seconds
            entry.state = controller?.settings.autoHideSeconds == choice.seconds ? .on : .off
            submenu.addItem(entry)
        }
        parent.submenu = submenu
        return parent
    }

    private func hidingMethodMenu() -> NSMenuItem {
        let parent = item("Hiding Method", symbol: nil, action: nil)
        let submenu = NSMenu()
        for method in HidingMethod.allCases {
            let entry = item(method.title, symbol: nil, action: #selector(setHidingMethod(_:)))
            entry.representedObject = method.rawValue
            entry.state = controller?.hidingMethod == method ? .on : .off
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        submenu.addItem(
            item("Allow Access to Menu Bar Settings…", symbol: "folder", action: #selector(grantNativeAccess)))
        parent.submenu = submenu
        return parent
    }

    private func item(_ title: String, symbol: String?, action: Selector?, keyEquivalent: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        entry.target = self
        if let symbol { entry.image = Self.symbol(symbol) }
        return entry
    }

    // MARK: - Actions

    @objc private func toggle() { controller?.toggle() }

    @objc private func refresh() { controller?.rescan() }

    @objc private func restore() { controller?.restoreVisibility() }

    @objc private func setHidingMethod(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let method = HidingMethod(rawValue: raw) else { return }
        controller?.setHidingMethod(method)
        if let error = controller?.lastError { showHidingError(error) }
    }

    @objc private func grantNativeAccess() {
        do {
            guard try nativeAccess?.requestAccess() == true else { return }
            controller?.show()
            controller?.setHidingMethod(.systemSettings)
            let selectionError = controller?.lastError
            controller?.restoreVisibility()
            if let error = selectionError ?? controller?.lastError { throw error }
        } catch {
            showHidingError(error)
        }
    }

    private func showHidingError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Could Not Change Menu Bar Visibility"
        var detail = error.localizedDescription
        if case SystemTrackedApplicationsStore.Failure.unreadable = error {
            detail +=
                "\n\nUse Hiding Method → Allow Access to Menu Bar Settings. "
                + "Select only the group.com.apple.controlcenter folder."
        }
        alert.informativeText = detail
        alert.runModal()
    }

    @objc private func setAutoHide(_ sender: NSMenuItem) {
        controller?.setAutoHideSeconds(sender.tag)
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            Log.ui.error("launch at login failed: \(error.localizedDescription)")
        }
    }

    @objc private func openAccessibility() {
        MenuBarScanner.requestTrust()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func moveToApplications() {
        ApplicationsMover.move()
    }

    @objc private func openRepository() {
        NSWorkspace.shared.open(Self.repositoryURL)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
