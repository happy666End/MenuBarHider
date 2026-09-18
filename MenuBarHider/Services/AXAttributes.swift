import ApplicationServices
import Foundation

/// Typed reads of Accessibility attributes; every failure collapses to nil.
enum AXAttributes {
    static func extrasMenuBar(pid: pid_t, timeout: Float) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        return element(app, kAXExtrasMenuBarAttribute)
    }

    static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = raw(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    static func elements(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
        raw(element, name) as? [AXUIElement] ?? []
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        raw(element, name) as? String
    }

    static func point(_ element: AXUIElement, _ name: String) -> CGPoint? {
        guard let value = axValue(element, name) else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    static func size(_ element: AXUIElement, _ name: String) -> CGSize? {
        guard let value = axValue(element, name) else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    private static func axValue(_ element: AXUIElement, _ name: String) -> AXValue? {
        guard let value = raw(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXValue.self)
    }

    private static func raw(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}
