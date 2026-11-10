import ApplicationServices
import Foundation

enum AXAttributeError: Error {
    case accessibility(AXError)
    case invalidValue
}

struct AXAttributeReader {
    typealias Application = (pid_t, Float) -> Result<AXUIElement, AXAttributeError>
    typealias CopyAttribute = (AXUIElement, String) -> (AXError, AnyObject?)

    let application: Application
    let copyAttribute: CopyAttribute

    init(
        application: @escaping Application = AXAttributeReader.makeApplication,
        copyAttribute: @escaping CopyAttribute = AXAttributeReader.copyValue
    ) {
        self.application = application
        self.copyAttribute = copyAttribute
    }

    func extrasMenuBar(pid: pid_t, timeout: Float) throws -> AXUIElement? {
        let app = try application(pid, timeout).get()
        do {
            let value = try raw(app, kAXExtrasMenuBarAttribute)
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { throw AXAttributeError.invalidValue }
            return unsafeDowncast(value, to: AXUIElement.self)
        } catch AXAttributeError.accessibility(let error) where error == .noValue || error == .attributeUnsupported {
            return nil
        }
    }

    func elements(_ element: AXUIElement, _ name: String) throws -> [AXUIElement] {
        let value = try raw(element, name)
        guard let children = value as? [AnyObject],
            children.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() })
        else { throw AXAttributeError.invalidValue }
        return children.map { unsafeDowncast($0, to: AXUIElement.self) }
    }

    func optionalString(_ element: AXUIElement, _ name: String) throws -> String? {
        do {
            guard let value = try raw(element, name) as? String else { throw AXAttributeError.invalidValue }
            return value
        } catch AXAttributeError.accessibility(let error) where error == .noValue || error == .attributeUnsupported {
            return nil
        }
    }

    func point(_ element: AXUIElement, _ name: String) throws -> CGPoint {
        let value = try raw(element, name)
        guard CFGetTypeID(value) == AXValueGetTypeID() else { throw AXAttributeError.invalidValue }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgPoint else { throw AXAttributeError.invalidValue }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point), point.x.isFinite, point.y.isFinite else {
            throw AXAttributeError.invalidValue
        }
        return point
    }

    private func raw(_ element: AXUIElement, _ name: String) throws -> AnyObject {
        let (error, value) = copyAttribute(element, name)
        guard error == .success else { throw AXAttributeError.accessibility(error) }
        guard let value else { throw AXAttributeError.invalidValue }
        return value
    }

    static func makeApplication(pid: pid_t, timeout: Float) -> Result<AXUIElement, AXAttributeError> {
        let app = AXUIElementCreateApplication(pid)
        let error = AXUIElementSetMessagingTimeout(app, timeout)
        return error == .success ? .success(app) : .failure(.accessibility(error))
    }

    static func copyValue(_ element: AXUIElement, _ name: String) -> (AXError, AnyObject?) {
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return (error, value)
    }
}

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
        let (error, value) = AXAttributeReader.copyValue(element, name)
        return error == .success ? value : nil
    }
}
