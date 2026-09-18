import XCTest

@testable import MenuBarHider

final class HiddenSetTests: XCTestCase {
    func testPartitionKeepsOnlyItemsLeftOfSeparator() {
        let items = [
            MenuBarItemPosition(bundleID: "left.one", x: 100),
            MenuBarItemPosition(bundleID: "left.two", x: 199),
            MenuBarItemPosition(bundleID: "at.separator", x: 200),
            MenuBarItemPosition(bundleID: "right.one", x: 300),
        ]
        XCTAssertEqual(
            HiddenSet.partition(items: items, leftSeparatorX: nil, separatorX: 200), ["left.one", "left.two"])
    }

    func testPartitionWithMultipleItemsPerAppHidesAppIfAnyItemIsLeft() {
        let items = [
            MenuBarItemPosition(bundleID: "app", x: 100),
            MenuBarItemPosition(bundleID: "app", x: 300),
        ]
        XCTAssertEqual(HiddenSet.partition(items: items, leftSeparatorX: nil, separatorX: 200), ["app"])
    }

    func testLeftSeparatorKeepsItemsLeftOfItVisible() {
        let items = [
            MenuBarItemPosition(bundleID: "app1", x: 50),
            MenuBarItemPosition(bundleID: "app2", x: 120),
            MenuBarItemPosition(bundleID: "app3", x: 150),
            MenuBarItemPosition(bundleID: "app4", x: 300),
        ]
        XCTAssertEqual(HiddenSet.partition(items: items, leftSeparatorX: 100, separatorX: 200), ["app2", "app3"])
    }

    func testItemExactlyAtLeftSeparatorIsHidden() {
        let items = [MenuBarItemPosition(bundleID: "edge", x: 100)]
        XCTAssertEqual(HiddenSet.partition(items: items, leftSeparatorX: 100, separatorX: 200), ["edge"])
    }

    func testAllowListExcludesHiddenAndIncludesAlwaysAllowed() {
        let allowed = HiddenSet.allowList(
            running: ["a", "b", "c"],
            hidden: ["b"],
            alwaysAllowed: ["sys", "a"]
        )
        XCTAssertEqual(allowed, ["a", "c", "sys"])
    }

    func testAlwaysAllowedWinsOverHidden() {
        let allowed = HiddenSet.allowList(running: ["x"], hidden: ["x"], alwaysAllowed: ["x"])
        XCTAssertEqual(allowed, ["x"])
    }
}
