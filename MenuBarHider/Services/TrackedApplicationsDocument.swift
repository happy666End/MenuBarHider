import CoreFoundation
import Foundation

struct TrackedApplicationsDocument {
    enum Failure: LocalizedError {
        case malformedDocument
        case malformedRecord
        case duplicateOwner
        case ambiguousOwner
        case missingOwner

        var errorDescription: String? {
            switch self {
            case .malformedDocument: "The tracked applications preference has an unsupported format."
            case .malformedRecord: "A tracked application record has an unsupported format."
            case .duplicateOwner: "The tracked applications preference contains duplicate owners."
            case .ambiguousOwner: "A menu bar application maps to more than one tracked owner."
            case .missingOwner: "A requested application is no longer tracked by macOS."
            }
        }
    }

    private struct Record {
        let bundleID: String
        let allowed: Bool
        let valueIndex: Int
        let menuBundles: Set<String>
    }

    private let originalData: Data
    private let elements: [Any]

    init(data: Data) throws {
        guard let propertyList = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let elements = propertyList as? [Any], elements.count.isMultiple(of: 2)
        else {
            throw Failure.malformedDocument
        }
        self.originalData = data
        self.elements = elements
    }

    func states() throws -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: try records().map { ($0.bundleID, $0.allowed) })
    }

    func owner(for bundleID: String) throws -> String? {
        let matches = try records().filter { $0.bundleID == bundleID || $0.menuBundles.contains(bundleID) }
        guard matches.count <= 1 else { throw Failure.ambiguousOwner }
        return matches.first?.bundleID
    }

    func settingAllowed(_ changes: [String: Bool]) throws -> Data {
        guard !changes.isEmpty else { return originalData }
        let records = try records()
        let owners = Set(records.map(\.bundleID))
        guard Set(changes.keys).isSubset(of: owners) else { throw Failure.missingOwner }

        var updated = elements
        var changed = false
        for record in records {
            guard let allowed = changes[record.bundleID], allowed != record.allowed else { continue }
            guard var value = elements[record.valueIndex] as? [String: Any] else { throw Failure.malformedRecord }
            value["isAllowed"] = allowed
            updated[record.valueIndex] = value
            changed = true
        }
        guard changed else { return originalData }
        return try PropertyListSerialization.data(fromPropertyList: updated, format: .binary, options: 0)
    }

    private func records() throws -> [Record] {
        var result: [Record] = []
        var owners: Set<String> = []
        for keyIndex in stride(from: 0, to: elements.count, by: 2) {
            guard let bundleID = try Self.bundleID(in: elements[keyIndex]) else { continue }
            guard owners.insert(bundleID).inserted else { throw Failure.duplicateOwner }
            guard let value = elements[keyIndex + 1] as? [String: Any],
                let number = value["isAllowed"] as? NSNumber,
                CFGetTypeID(number) == CFBooleanGetTypeID()
            else {
                throw Failure.malformedRecord
            }
            if let location = value["location"], try Self.bundleID(in: location) != bundleID {
                throw Failure.malformedRecord
            }
            let menuBundles = try Self.menuBundles(in: value)
            result.append(
                Record(
                    bundleID: bundleID, allowed: number.boolValue,
                    valueIndex: keyIndex + 1, menuBundles: menuBundles))
        }
        return result
    }

    private static func menuBundles(in value: [String: Any]) throws -> Set<String> {
        guard let locations = value["menuItemLocations"] else { return [] }
        guard let locations = locations as? [Any] else { throw Failure.malformedRecord }
        var bundles: Set<String> = []
        for location in locations {
            guard let bundleID = try bundleID(in: location) else { continue }
            guard bundles.insert(bundleID).inserted else { throw Failure.ambiguousOwner }
        }
        return bundles
    }

    private static func bundleID(in key: Any) throws -> String? {
        guard let key = key as? [String: Any], let bundle = key["bundle"] else { return nil }
        guard key.count == 1, let payload = bundle as? [String: Any],
            let bundleID = payload["_0"] as? String
        else {
            throw Failure.malformedRecord
        }
        return bundleID.isEmpty ? nil : bundleID
    }
}
