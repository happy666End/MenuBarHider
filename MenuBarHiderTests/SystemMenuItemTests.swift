import ApplicationServices
import XCTest

@testable import MenuBarHider

final class SystemMenuItemTests: XCTestCase {
    func testSystemControlsUseTheirOwnSelectionKeys() {
        let cases = [
            ("battery", "battery"), ("bluetooth", "bluetooth"), ("display", "displays"),
            ("keyboard-brightness", "keyboard"), ("sound", "volume"), ("wifi", "wifi"),
            ("screen-mirroring", "screenMirroring"),
        ]
        for (accessibilityName, selectionName) in cases {
            XCTAssertEqual(
                SystemItems.selectionID(forAccessibilityIdentifier: "com.apple.menuextra.\(accessibilityName)"),
                "system-item:\(selectionName)")
        }
        for name in ["clock", "controlcenter", "future-control"] {
            XCTAssertNil(SystemItems.selectionID(forAccessibilityIdentifier: "com.apple.menuextra.\(name)"))
        }
    }

    func testRestrictionCannotHideClockControlCenterOrUnknownSystemTypes() {
        let allowed = Set(SystemItems.allowedIdentifiers(hiding: [0, 1, 2, 3, 4, 5, 6, 7, 8, 127]).map(\.intValue))
        XCTAssertTrue(allowed.isDisjoint(with: [0, 1, 3, 4, 5, 6, 7]))
        XCTAssertTrue(allowed.isSuperset(of: [2, 8, 127]))
    }

    func testSystemScannerReadsGroupedControlsAndPreservesNegativeCoordinates() {
        let fixture = SystemAXFixture(identifiers: [
            "com.apple.menuextra.wifi", "com.apple.menuextra.keyboard-brightness",
            "com.apple.menuextra.clock", "com.apple.menuextra.controlcenter",
        ])
        let scan = fixture.scan()
        XCTAssertEqual(
            scan.positions,
            [
                .init(bundleID: "system-item:wifi", x: -200),
                .init(bundleID: "system-item:keyboard", x: -160),
            ])
        XCTAssertTrue(scan.failedBundleIDs.isEmpty)
    }

    func testEmptyAXGroupPreservesUnobservedSystemSelections() {
        let fixture = SystemAXFixture(identifiers: ["com.apple.menuextra.wifi"])
        fixture.emptyGroups = true
        let scan = fixture.scan()
        XCTAssertTrue(scan.positions.isEmpty)
        XCTAssertTrue(scan.failedBundleIDs.contains("system-item:wifi"))
    }

    func testSystemReadFailurePreservesAllSelections() {
        let fixture = SystemAXFixture(identifiers: ["com.apple.menuextra.wifi"])
        fixture.positionError = .cannotComplete
        let scan = fixture.scan()
        XCTAssertTrue(scan.positions.isEmpty)
        XCTAssertEqual(
            scan.failedBundleIDs,
            [
                "system-item:battery", "system-item:bluetooth", "system-item:displays", "system-item:keyboard",
                "system-item:volume", "system-item:wifi", "system-item:screenMirroring",
            ])
    }

    func testUnknownControlDoesNotEraseUnidentifiedPreviousSelections() {
        let fixture = SystemAXFixture(identifiers: ["com.apple.menuextra.wifi", "com.apple.menuextra.future"])
        let scan = fixture.scan()
        XCTAssertEqual(scan.positions, [.init(bundleID: "system-item:wifi", x: -200)])
        XCTAssertFalse(scan.failedBundleIDs.contains("system-item:wifi"))
        XCTAssertTrue(scan.failedBundleIDs.contains("system-item:keyboard"))
    }

    func testDuplicateSystemIdentityIsTreatedAsAnAmbiguousScan() {
        let fixture = SystemAXFixture(identifiers: ["com.apple.menuextra.wifi", "com.apple.menuextra.wifi"])
        let scan = fixture.scan()
        XCTAssertTrue(scan.positions.isEmpty)
        XCTAssertEqual(scan.failedBundleIDs, ["system-item:wifi"])
    }
}

private final class SystemAXFixture {
    let app = AXUIElementCreateApplication(-100)
    let bar = AXUIElementCreateApplication(-101)
    let identifiers: [String]
    var positionError: AXError?
    var emptyGroups = false

    init(identifiers: [String]) { self.identifiers = identifiers }

    func scan() -> MenuBarScan {
        let groups = identifiers.indices.map { AXUIElementCreateApplication(pid_t(-200 - $0)) }
        let leaves = identifiers.indices.map { AXUIElementCreateApplication(pid_t(-300 - $0)) }
        let reader = AXAttributeReader(
            application: { [self] _, _ in .success(app) },
            copyAttribute: { [self] element, name in
                if CFEqual(element, app), name == kAXExtrasMenuBarAttribute { return (.success, bar) }
                if CFEqual(element, bar), name == kAXChildrenAttribute { return (.success, groups as NSArray) }
                if let index = groups.firstIndex(where: { CFEqual($0, element) }) {
                    if name == kAXRoleAttribute { return (.success, kAXGroupRole as NSString) }
                    if name == kAXChildrenAttribute {
                        return (.success, (emptyGroups ? [] : [leaves[index]]) as NSArray)
                    }
                    return (.noValue, nil)
                }
                if let index = leaves.firstIndex(where: { CFEqual($0, element) }) {
                    if name == kAXRoleAttribute { return (.success, kAXMenuBarItemRole as NSString) }
                    if name == kAXIdentifierAttribute { return (.success, identifiers[index] as NSString) }
                    if name == kAXPositionAttribute {
                        if let positionError { return (positionError, nil) }
                        var point = CGPoint(x: -200 + index * 40, y: 4)
                        return (.success, AXValueCreate(.cgPoint, &point))
                    }
                }
                return (.attributeUnsupported, nil)
            })
        return MenuBarScanner.systemItemPositions(pid: -100, reader: reader)
    }
}
