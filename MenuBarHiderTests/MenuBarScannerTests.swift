import ApplicationServices
import XCTest

@testable import MenuBarHider

final class MenuBarScannerTests: XCTestCase {
    func testAppleAgentsAreScannedButSharedHostsAndDaemonsAreExcluded() {
        let fixture = ScanAXFixture()
        let candidates: [MenuBarScanner.Application] = [
            .init(pid: -20, bundleID: "com.apple.TextInputMenuAgent", activationPolicy: .accessory),
            .init(pid: -21, bundleID: "com.apple.future-agent", activationPolicy: .accessory),
            .init(pid: -22, bundleID: "third.party", activationPolicy: .regular),
            .init(pid: -23, bundleID: "com.apple.MenuBarAgent", activationPolicy: .accessory),
            .init(pid: -24, bundleID: "com.apple.systemuiserver", activationPolicy: .accessory),
            .init(pid: -25, bundleID: "com.apple.controlcenter", activationPolicy: .accessory),
            .init(pid: -26, bundleID: "background.daemon", activationPolicy: .prohibited),
        ]
        let scanner = MenuBarScanner(
            extras: FakeExtras(), applications: { candidates }, reader: fixture.reader,
            systemItems: { MenuBarScan(positions: []) })

        let scan = scanner.scan()

        XCTAssertEqual(
            Set(scan.positions.map(\.bundleID)),
            [
                "com.apple.TextInputMenuAgent", "com.apple.future-agent", "third.party",
            ])
        XCTAssertTrue(scan.failedBundleIDs.isEmpty)
    }

    func testExtrasBarAbsenceIsHealthyOnlyForNoValueAndUnsupported() {
        for error in [AXError.noValue, .attributeUnsupported] {
            let scan = scanApplication(extras: (error, nil))
            XCTAssertEqual(scan.positions, [])
            XCTAssertEqual(scan.failedBundleIDs, [])
        }
        for error in [AXError.cannotComplete, .apiDisabled, .invalidUIElement, .failure] {
            let scan = scanApplication(extras: (error, nil))
            XCTAssertEqual(scan.positions, [])
            XCTAssertEqual(scan.failedBundleIDs, ["example.app"])
        }
    }

    func testFailedChildReadDiscardsAllPositionsForThatApplication() {
        for error in [AXError.cannotComplete, .noValue, .attributeUnsupported] {
            let fixture = ScanAXFixture()
            fixture.children = (error, nil)
            let scan = fixture.scan()
            XCTAssertEqual(scan.positions, [])
            XCTAssertEqual(scan.failedBundleIDs, ["example.app"])
        }
    }

    func testFailedPositionDiscardsEarlierSuccessfulChildPositions() {
        let fixture = ScanAXFixture()
        fixture.secondPosition = (.cannotComplete, nil)
        let scan = fixture.scan()
        XCTAssertEqual(scan.positions, [])
        XCTAssertEqual(scan.failedBundleIDs, ["example.app"])
    }

    func testMissingOrMalformedPositionFailsInsteadOfConfirmingAbsence() {
        for response: (AXError, AnyObject?) in [(.noValue, nil), (.success, "bad" as NSString), (.success, nil)] {
            let fixture = ScanAXFixture()
            fixture.secondPosition = response
            let scan = fixture.scan()
            XCTAssertEqual(scan.positions, [])
            XCTAssertEqual(scan.failedBundleIDs, ["example.app"])
        }
    }

    func testSuccessfulAndEmptyApplicationsAreAuthoritative() {
        let fixture = ScanAXFixture()
        XCTAssertEqual(
            fixture.scan().positions,
            [
                MenuBarItemPosition(bundleID: "example.app", x: 700),
                MenuBarItemPosition(bundleID: "example.app", x: 800),
            ])
        XCTAssertEqual(fixture.scan().failedBundleIDs, [])
        fixture.children = (.success, [] as NSArray)
        XCTAssertEqual(fixture.scan().positions, [])
        XCTAssertEqual(fixture.scan().failedBundleIDs, [])
    }

    func testMalformedExtrasOrChildrenFailApplication() {
        let badBar = scanApplication(extras: (.success, "bad" as NSString))
        XCTAssertEqual(badBar.failedBundleIDs, ["example.app"])
        let fixture = ScanAXFixture()
        fixture.children = (.success, ["bad"] as NSArray)
        XCTAssertEqual(fixture.scan().failedBundleIDs, ["example.app"])
    }

    func testApplicationSetupFailureIsPreserved() {
        let reader = AXAttributeReader(application: { _, _ in .failure(.accessibility(.cannotComplete)) })
        let scan = MenuBarScanner.positions(pid: -1, bundleID: "example.app", reader: reader)
        XCTAssertEqual(scan.positions, [])
        XCTAssertEqual(scan.failedBundleIDs, ["example.app"])
    }

    func testMenuExtraMismatchAndReadFailurePreserveKnownLoadedIDs() {
        let fixture = ScanAXFixture()
        let loaded = ["com.apple.menuextra.vpn"]
        let mismatch = MenuBarScanner.menuExtraPositions(pid: -1, loadedIDs: loaded, reader: fixture.reader)
        XCTAssertEqual(mismatch.positions, [])
        XCTAssertEqual(mismatch.failedBundleIDs, Set(loaded))
        fixture.secondPosition = (.noValue, nil)
        let failure = MenuBarScanner.menuExtraPositions(pid: -1, loadedIDs: loaded, reader: fixture.reader)
        XCTAssertEqual(failure.positions, [])
        XCTAssertEqual(failure.failedBundleIDs, Set(loaded))
        let missingServer = MenuBarScanner.menuExtraPositions(pid: nil, loadedIDs: loaded, reader: fixture.reader)
        XCTAssertEqual(missingServer.failedBundleIDs, Set(loaded))
    }

    func testMenuExtraPositionsKeepLoadOrderAndNoLoadedExtrasAreHealthy() {
        let fixture = ScanAXFixture()
        let loaded = ["com.apple.menuextra.vpn", "com.apple.menuextra.TimeMachine"]
        let scan = MenuBarScanner.menuExtraPositions(pid: -1, loadedIDs: loaded, reader: fixture.reader)
        XCTAssertEqual(
            scan.positions,
            [MenuBarItemPosition(bundleID: loaded[0], x: 700), MenuBarItemPosition(bundleID: loaded[1], x: 800)])
        XCTAssertEqual(scan.failedBundleIDs, [])
        XCTAssertEqual(MenuBarScanner.menuExtraPositions(pid: nil, loadedIDs: []).failedBundleIDs, [])
    }

    private func scanApplication(extras: (AXError, AnyObject?)) -> MenuBarScan {
        let fixture = ScanAXFixture()
        fixture.extras = extras
        return fixture.scan()
    }
}

private final class ScanAXFixture {
    let application = AXUIElementCreateApplication(-11)
    let bar = AXUIElementCreateApplication(-12)
    let first = AXUIElementCreateApplication(-13)
    let second = AXUIElementCreateApplication(-14)
    var extras: (AXError, AnyObject?)?
    var children: (AXError, AnyObject?)?
    var secondPosition: (AXError, AnyObject?)?

    var reader: AXAttributeReader {
        AXAttributeReader(
            application: { [self] _, _ in .success(application) },
            copyAttribute: { [self] element, name in
                switch name {
                case kAXExtrasMenuBarAttribute: return extras ?? (.success, bar)
                case kAXChildrenAttribute: return children ?? (.success, [first, second] as NSArray)
                case kAXPositionAttribute:
                    if CFEqual(element, second), let secondPosition { return secondPosition }
                    var point = CGPoint(x: CFEqual(element, first) ? 700 : 800, y: 10)
                    return (.success, AXValueCreate(.cgPoint, &point))
                default: return (.attributeUnsupported, nil)
                }
            })
    }

    func scan() -> MenuBarScan {
        MenuBarScanner.positions(pid: -1, bundleID: "example.app", reader: reader)
    }
}
