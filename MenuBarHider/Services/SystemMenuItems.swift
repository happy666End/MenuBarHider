import AppKit
import ApplicationServices

/// Where the clock item hosted by MenuBarAgent sits on screen.
final class SystemMenuItems {
    private static let clockIdentifier = "com.apple.menuextra.clock"
    /// The frame is queried on pointer movement, so it is cached briefly to avoid AX round trips.
    private static let frameLifetime: TimeInterval = 2
    /// The element changes only when MenuBarAgent restarts; re-resolving it is the expensive part.
    private static let elementLifetime: TimeInterval = 60

    private var cachedFrame: (frame: CGRect, at: Date)?
    private var cachedElement: (element: AXUIElement, at: Date)?

    /// Frame in Cocoa screen coordinates; a miss is not cached, the bar is usually mid-relayout.
    func clockFrame() -> CGRect? {
        if let cachedFrame, Date().timeIntervalSince(cachedFrame.at) < Self.frameLifetime { return cachedFrame.frame }
        guard let frame = queryClockFrame() else {
            Log.ui.error("clock frame unavailable")
            return nil
        }
        cachedFrame = (frame, Date())
        return frame
    }

    private func queryClockFrame() -> CGRect? {
        guard let element = clockElement(),
            let origin = AXAttributes.point(element, kAXPositionAttribute),
            let size = AXAttributes.size(element, kAXSizeAttribute)
        else {
            cachedElement = nil
            return nil
        }
        // Accessibility reports a top-left origin; Cocoa screen coordinates start bottom-left.
        guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first
        else { return nil }
        let flippedY = primary.frame.height - origin.y - size.height
        return CGRect(x: origin.x, y: flippedY, width: size.width, height: size.height)
    }

    private func clockElement() -> AXUIElement? {
        if let cachedElement, Date().timeIntervalSince(cachedElement.at) < Self.elementLifetime {
            return cachedElement.element
        }
        guard
            let agent = NSRunningApplication.runningApplications(withBundleIdentifier: SystemItems.menuBarAgentBundleID)
                .first,
            let bar = AXAttributes.extrasMenuBar(pid: agent.processIdentifier, timeout: 0.3)
        else { return nil }
        // Items are wrapped in hosting groups, so the clock sits one level below the bar.
        for group in AXAttributes.elements(bar, kAXChildrenAttribute) {
            for child in AXAttributes.elements(group, kAXChildrenAttribute)
            where AXAttributes.string(child, kAXIdentifierAttribute) == Self.clockIdentifier {
                cachedElement = (child, Date())
                return child
            }
        }
        return nil
    }
}
