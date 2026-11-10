import AppKit
import XCTest

@testable import MenuBarHider

final class SystemMenuItemsTests: XCTestCase {
    private let builtIn = CGRect(x: 1578, y: 0, width: 112, height: 34)
    private let external = CGRect(x: 4138, y: 0, width: 112, height: 30)

    private func screenFrame(at point: CGPoint) -> CGRect? {
        let screens = [
            CGRect(x: 0, y: 0, width: 1710, height: 1107),
            CGRect(x: 1710, y: -333, width: 2560, height: 1440),
            CGRect(x: -2560, y: 1107, width: 2560, height: 1440),
        ]
        return screens.first(where: { $0.contains(point) })
    }

    private func makeResolver() -> SystemMenuItems {
        let frames = [builtIn, external]
        return SystemMenuItems(
            primaryScreenHeight: { 1107 },
            screenFrame: screenFrame,
            hitTest: { point in frames.first(where: { $0.contains(point) }) }
        )
    }

    func testRecognizesClockPaddingOutsideText() {
        let resolver = makeResolver()
        let expected = CGRect(x: 1578, y: 1073, width: 112, height: 34)

        XCTAssertEqual(resolver.clockFrame(at: CGPoint(x: 1640, y: 1106)), expected)
        XCTAssertEqual(resolver.clockFrame(at: CGPoint(x: 1640, y: 1074)), expected)
    }

    func testSwitchingDisplaysDoesNotReuseOtherClocksFrame() {
        let resolver = makeResolver()

        XCTAssertEqual(
            resolver.clockFrame(at: CGPoint(x: 1640, y: 1090)),
            CGRect(x: 1578, y: 1073, width: 112, height: 34))
        XCTAssertEqual(
            resolver.clockFrame(at: CGPoint(x: 4200, y: 1090)),
            CGRect(x: 4138, y: 1077, width: 112, height: 30))
        XCTAssertEqual(
            resolver.clockFrame(at: CGPoint(x: 1640, y: 1090)),
            CGRect(x: 1578, y: 1073, width: 112, height: 34))
    }

    func testConvertsDisplayAboveAndLeftOfPrimary() {
        let resolver = SystemMenuItems(
            primaryScreenHeight: { 1107 },
            screenFrame: screenFrame,
            hitTest: { point in
                XCTAssertEqual(point, CGPoint(x: -70, y: -1430))
                return CGRect(x: -132, y: -1440, width: 112, height: 30)
            }
        )

        XCTAssertEqual(
            resolver.clockFrame(at: CGPoint(x: -70, y: 2537)),
            CGRect(x: -132, y: 2517, width: 112, height: 30))
    }

    func testPointOutsideClockDoesNotReuseCachedFrame() {
        let resolver = makeResolver()
        XCTAssertNotNil(resolver.clockFrame(at: CGPoint(x: 1640, y: 1090)))

        XCTAssertNil(resolver.clockFrame(at: CGPoint(x: 1550, y: 1090)))
        XCTAssertNil(resolver.clockFrame(at: CGPoint(x: 1640, y: 1050)))
    }

    func testScreenChangeInvalidatesCachedCoordinates() {
        var available = true
        let resolver = SystemMenuItems(
            primaryScreenHeight: { 1107 },
            screenFrame: screenFrame,
            hitTest: { [builtIn] _ in available ? builtIn : nil }
        )
        let point = CGPoint(x: 1640, y: 1090)
        XCTAssertNotNil(resolver.clockFrame(at: point))

        available = false
        resolver.invalidateCache()

        XCTAssertNil(resolver.clockFrame(at: point))
    }

    func testFailedHitIsRetried() {
        var available = false
        let resolver = SystemMenuItems(
            primaryScreenHeight: { 1107 },
            screenFrame: screenFrame,
            hitTest: { [builtIn] _ in available ? builtIn : nil }
        )
        let point = CGPoint(x: 1640, y: 1090)
        XCTAssertNil(resolver.clockFrame(at: point))

        available = true

        XCTAssertEqual(resolver.clockFrame(at: point), CGRect(x: 1578, y: 1073, width: 112, height: 34))
    }

    func testMissingPrimaryDisplayReturnsNoClock() {
        let resolver = SystemMenuItems(
            primaryScreenHeight: { nil }, screenFrame: screenFrame, hitTest: { [builtIn] _ in builtIn })

        XCTAssertNil(resolver.clockFrame(at: CGPoint(x: 1640, y: 1090)))
    }

    func testFreshClockFrameAvoidsHitTestsElsewhereOnSameScreen() {
        var queries = 0
        let resolver = SystemMenuItems(
            primaryScreenHeight: { 1107 },
            screenFrame: screenFrame,
            hitTest: { [builtIn] _ in
                queries += 1
                return builtIn
            }
        )
        XCTAssertNotNil(resolver.clockFrame(at: CGPoint(x: 1640, y: 1090)))

        for x in stride(from: 100, through: 1500, by: 100) {
            XCTAssertNil(resolver.clockFrame(at: CGPoint(x: x, y: 1090)))
        }

        XCTAssertEqual(queries, 1, "moving elsewhere in the bar must not perform AX IPC for each event")
    }

    func testEachDisplayRetainsItsOwnCachedFrame() {
        var queries = 0
        let frames = [builtIn, external]
        let resolver = SystemMenuItems(
            primaryScreenHeight: { 1107 },
            screenFrame: screenFrame,
            hitTest: { point in
                queries += 1
                return frames.first(where: { $0.contains(point) })
            }
        )

        for _ in 0..<3 {
            XCTAssertNotNil(resolver.clockFrame(at: CGPoint(x: 1640, y: 1090)))
            XCTAssertNotNil(resolver.clockFrame(at: CGPoint(x: 4200, y: 1090)))
        }

        XCTAssertEqual(queries, 2, "switching displays must keep both cached click targets")
    }
}
