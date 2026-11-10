import AppKit
import ApplicationServices

final class SystemMenuItems {
    private struct CachedFrame {
        let screen: CGRect
        let frame: CGRect
        let at: Date
    }

    private static let clockIdentifier = "com.apple.menuextra.clock"
    private static let frameLifetime: TimeInterval = 2

    private let primaryScreenHeight: () -> CGFloat?
    private let screenFrame: (CGPoint) -> CGRect?
    private let hitTest: (CGPoint) -> CGRect?
    private var cachedFrames: [CachedFrame] = []

    init(
        primaryScreenHeight: @escaping () -> CGFloat? = SystemMenuItems.primaryHeight,
        screenFrame: @escaping (CGPoint) -> CGRect? = SystemMenuItems.screenFrame,
        hitTest: @escaping (CGPoint) -> CGRect? = SystemMenuItems.hitTestClock
    ) {
        self.primaryScreenHeight = primaryScreenHeight
        self.screenFrame = screenFrame
        self.hitTest = hitTest
    }

    func clockFrame(at location: CGPoint) -> CGRect? {
        guard let screen = screenFrame(location) else { return nil }
        let now = Date()
        cachedFrames.removeAll { now.timeIntervalSince($0.at) >= Self.frameLifetime }
        if let cached = cachedFrames.first(where: { $0.screen == screen }) {
            return cached.frame.contains(location) ? cached.frame : nil
        }
        guard let height = primaryScreenHeight(),
            let frame = hitTest(CGPoint(x: location.x, y: height - location.y))
        else { return nil }
        // AX uses the primary display's top-left origin even for secondary-display hits.
        let cocoaFrame = CGRect(x: frame.minX, y: height - frame.maxY, width: frame.width, height: frame.height)
        guard cocoaFrame.contains(location) else { return nil }
        cachedFrames.append(CachedFrame(screen: screen, frame: cocoaFrame, at: now))
        Log.ui.error("clock click target: \(String(describing: cocoaFrame), privacy: .public)")
        return cocoaFrame
    }

    func invalidateCache() {
        cachedFrames.removeAll()
    }

    private static func primaryHeight() -> CGFloat? {
        (NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first)?.frame.height
    }

    private static func screenFrame(at location: CGPoint) -> CGRect? {
        NSScreen.screens.first(where: { $0.frame.contains(location) })?.frame
    }

    private static func hitTestClock(at point: CGPoint) -> CGRect? {
        guard
            let app = NSRunningApplication.runningApplications(withBundleIdentifier: SystemItems.menuBarAgentBundleID)
                .first
        else { return nil }
        let agent = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(agent, 0.3)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(agent, Float(point.x), Float(point.y), &hit) == .success,
            let hit
        else { return nil }

        if AXAttributes.string(hit, kAXIdentifierAttribute) == clockIdentifier {
            // The hosting group owns the clock's clickable padding, including text.
            guard let parent = AXAttributes.element(hit, kAXParentAttribute),
                AXAttributes.string(parent, kAXRoleAttribute) == kAXGroupRole,
                let parentFrame = frame(of: parent)
            else { return frame(of: hit) }
            return parentFrame
        }

        guard AXAttributes.string(hit, kAXRoleAttribute) == kAXGroupRole,
            AXAttributes.elements(hit, kAXChildrenAttribute).contains(where: {
                AXAttributes.string($0, kAXIdentifierAttribute) == clockIdentifier
            })
        else { return nil }
        return frame(of: hit)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let origin = AXAttributes.point(element, kAXPositionAttribute),
            let size = AXAttributes.size(element, kAXSizeAttribute), size.width > 0, size.height > 0
        else { return nil }
        return CGRect(origin: origin, size: size)
    }
}
