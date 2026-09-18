import AppKit

@MainActor
final class ClockHoverMonitor {
    private static let menuBarStripHeight: CGFloat = 40

    private let clock = SystemMenuItems()
    private let isRelevant: () -> Bool
    private var monitor: Any?
    private var isOverClock = false

    var onChange: ((Bool) -> Void)?

    init(isRelevant: @escaping () -> Bool) {
        self.isRelevant = isRelevant
    }

    func start() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            self?.update()
        }
    }

    func update() {
        let location = NSEvent.mouseLocation
        let over = isRelevant() && Self.isInMenuBarStrip(location) && (clock.clockFrame()?.contains(location) ?? false)
        guard over != isOverClock else { return }
        isOverClock = over
        Log.ui.error("pointer over clock: \(over)")
        onChange?(over)
    }

    private static func isInMenuBarStrip(_ location: CGPoint) -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }) else { return false }
        return location.y > screen.frame.maxY - menuBarStripHeight
    }
}
