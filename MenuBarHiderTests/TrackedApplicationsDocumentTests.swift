import Foundation
import XCTest

@testable import MenuBarHider

final class TrackedApplicationsDocumentTests: XCTestCase {
    private func encode(_ value: Any, format: PropertyListSerialization.PropertyListFormat = .binary) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: format, options: 0)
    }

    private func document(_ array: [Any]) throws -> TrackedApplicationsDocument {
        try TrackedApplicationsDocument(data: encode(array))
    }

    func testReadsAllowedAndPreDisabledOwners() throws {
        let subject = try document([
            ["bundle": ["_0": "example.main"]], ["isAllowed": true],
            ["bundle": ["_0": "example.disabled"]], ["isAllowed": false],
        ])
        XCTAssertEqual(try subject.states(), ["example.main": true, "example.disabled": false])
    }

    func testResolvesDirectOwnerAndHelperBundle() throws {
        let subject = try document([
            ["bundle": ["_0": "example.main"]],
            ["isAllowed": true, "menuItemLocations": [["bundle": ["_0": "example.helper"]]]],
        ])
        XCTAssertEqual(try subject.owner(for: "example.main"), "example.main")
        XCTAssertEqual(try subject.owner(for: "example.helper"), "example.main")
        XCTAssertNil(try subject.owner(for: "example.missing"))
    }

    func testMutationPreservesUnrelatedValuesAndArrayOrder() throws {
        let fixture: [Any] = [
            ["adhocBinary": ["_0": ["relative": "file:///example/tool"]]],
            ["isAllowed": false, "future": [1, 2, 3]],
            ["bundle": ["_0": "example.main", "future": "key detail"]],
            [
                "isAllowed": true, "location": ["bundle": ["_0": "example.main"]],
                "menuItemLocations": [["bundle": ["_0": "example.helper"]]],
                "future": ["bytes": Data([0, 1, 255]), "date": Date(timeIntervalSince1970: 1234)],
            ],
            ["bundle": ["_0": "example.disabled"]], ["isAllowed": false],
            ["futureKey": ["arbitrary": true]], ["futureValue": ["one", "two"]],
        ]
        let changed = try document(fixture).settingAllowed(["example.main": false])
        let actual = try XCTUnwrap(PropertyListSerialization.propertyList(from: changed, format: nil) as? [Any])
        var expected = fixture
        var value = try XCTUnwrap(expected[3] as? [String: Any])
        value["isAllowed"] = false
        expected[3] = value
        XCTAssertTrue(NSArray(array: actual).isEqual(to: expected))
        XCTAssertEqual(Array(changed.prefix(8)), Array("bplist00".utf8))
    }

    func testUnchangedMutationReturnsOriginalBytesIncludingXML() throws {
        let bytes = try encode(
            [
                ["bundle": ["_0": "example.disabled"]], ["isAllowed": false],
            ], format: .xml)
        let subject = try TrackedApplicationsDocument(data: bytes)
        XCTAssertEqual(try subject.settingAllowed([:]), bytes)
        XCTAssertEqual(try subject.settingAllowed(["example.disabled": false]), bytes)
    }

    func testRejectsInvalidDataNonArrayAndOddArray() throws {
        XCTAssertThrowsError(try TrackedApplicationsDocument(data: Data("invalid".utf8)))
        XCTAssertThrowsError(try TrackedApplicationsDocument(data: encode(["key": true])))
        XCTAssertThrowsError(try document([["bundle": ["_0": "example.main"]]]))
    }

    func testRejectsNumericAndMissingAllowedFlags() throws {
        for value: Any in [NSNumber(value: 1), NSNumber(value: 0), "true", ["unexpected": true]] {
            let subject = try document([["bundle": ["_0": "example.main"]], ["isAllowed": value]])
            XCTAssertThrowsError(try subject.states())
            XCTAssertThrowsError(try subject.settingAllowed(["example.main": false]))
        }
        let missing = try document([["bundle": ["_0": "example.main"]], ["future": true]])
        XCTAssertThrowsError(try missing.states())
        XCTAssertThrowsError(try missing.settingAllowed(["example.main": false]))
    }

    func testRejectsMissingMutationTargetWithoutAddingRecord() throws {
        let subject = try document([])
        XCTAssertThrowsError(try subject.settingAllowed(["example.missing": false]))
    }

    func testRejectsDuplicateOwnersEvenWhenTheirFlagsAgree() throws {
        let subject = try document([
            ["bundle": ["_0": "example.main"]], ["isAllowed": true],
            ["bundle": ["_0": "example.main"]], ["isAllowed": true],
        ])
        XCTAssertThrowsError(try subject.states())
        XCTAssertThrowsError(try subject.owner(for: "example.main"))
        XCTAssertThrowsError(try subject.settingAllowed(["example.main": false]))
    }

    func testPreservesEmptyBundleRecordWithoutMakingItATarget() throws {
        let fixture: [Any] = [
            ["bundle": ["_0": ""]],
            ["isAllowed": true, "location": ["bundle": ["_0": ""]], "future": [1, 2]],
            ["bundle": ["_0": "example.main"]], ["isAllowed": true],
        ]
        let subject = try document(fixture)
        XCTAssertEqual(try subject.states(), ["example.main": true])
        XCTAssertNil(try subject.owner(for: ""))
        XCTAssertThrowsError(try subject.settingAllowed(["": false]))
        let changed = try subject.settingAllowed(["example.main": false])
        let actual = try XCTUnwrap(PropertyListSerialization.propertyList(from: changed, format: nil) as? [Any])
        var expected = fixture
        expected[3] = ["isAllowed": false]
        XCTAssertTrue(NSArray(array: actual).isEqual(to: expected))
    }

    func testRejectsAmbiguousHelperOwnerAndDirectOwnerCollision() throws {
        for secondOwner in ["example.other", "example.helper"] {
            let subject = try document([
                ["bundle": ["_0": "example.main"]],
                ["isAllowed": true, "menuItemLocations": [["bundle": ["_0": "example.helper"]]]],
                ["bundle": ["_0": secondOwner]],
                ["isAllowed": true, "menuItemLocations": [["bundle": ["_0": "example.helper"]]]],
            ])
            XCTAssertThrowsError(try subject.owner(for: "example.helper"))
        }
    }

    func testRejectsMalformedKnownBundleRecordsAndLocations() throws {
        let fixtures: [[Any]] = [
            [["bundle": ["_0": 4]], ["isAllowed": true]],
            [["bundle": ["_0": "example.main"], "adhocBinary": [:]], ["isAllowed": true]],
            [["bundle": ["_0": "example.main"]], "unexpected"],
            [["bundle": ["_0": "example.main"]], ["isAllowed": true, "menuItemLocations": "unexpected"]],
            [
                ["bundle": ["_0": "example.main"]],
                ["isAllowed": true, "location": ["bundle": ["_0": "example.other"]]],
            ],
        ]
        for fixture in fixtures {
            let subject = try document(fixture)
            XCTAssertThrowsError(try subject.states())
            XCTAssertThrowsError(try subject.owner(for: "example.main"))
            XCTAssertThrowsError(try subject.settingAllowed(["example.main": false]))
        }
    }

    func testAllowsAnOwnersOwnLocationInItsMenuItems() throws {
        let subject = try document([
            ["bundle": ["_0": "example.main"]],
            ["isAllowed": true, "menuItemLocations": [["bundle": ["_0": "example.main"]]]],
        ])
        XCTAssertEqual(try subject.owner(for: "example.main"), "example.main")
    }
}
