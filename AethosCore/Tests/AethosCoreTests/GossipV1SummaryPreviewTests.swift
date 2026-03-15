import Foundation
import XCTest
@testable import AethosCore

final class GossipV1SummaryPreviewTests: XCTestCase {
    func testSummaryPreviewGenerate_emptyEligible_returnsEmptyWindow() throws {
        let result = GossipV1SummaryPreview.generate(eligibleSorted: [], startAfter: nil)
        XCTAssertTrue(result.preview.isEmpty)
        XCTAssertNil(result.cursor)
    }

    func testSummaryPreviewGenerate_cursorBeyondEnd_returnsEmptyWindow() throws {
        let ids = try makeIDs(count: 4)
        let cursor = try makeItemID(prefix: 0xFF)

        let result = GossipV1SummaryPreview.generate(eligibleSorted: ids, startAfter: cursor)
        XCTAssertTrue(result.preview.isEmpty)
        XCTAssertNil(result.cursor)
    }

    func testSummaryPreviewGenerate_nonPresentCursor_selectsFirstStrictlyGreater() throws {
        let ids = try makeIDs(count: 4)
        let cursor = try makeItemID(prefix: 0x00, tail: 0x80)

        let result = GossipV1SummaryPreview.generate(eligibleSorted: ids, startAfter: cursor)
        XCTAssertEqual(result.preview, Array(ids.dropFirst()))
        XCTAssertNil(result.cursor)
    }

    func testSummaryPreviewGenerate_duplicatesAreRemoved_deterministically() throws {
        let a = try makeItemID(prefix: 0x01)
        let b = try makeItemID(prefix: 0x02)
        let c = try makeItemID(prefix: 0x03)

        let result = GossipV1SummaryPreview.generate(
            eligibleSorted: [c, a, b, b, a],
            startAfter: nil
        )

        XCTAssertEqual(result.preview, [a, b, c])
        XCTAssertNil(result.cursor)
    }

    func testSummaryPreviewGenerate_pagingIsDeterministic_withCursorWindows() throws {
        let ids = try makeIDs(count: GossipV1.MAX_SUMMARY_PREVIEW_ITEMS + 6)

        let page1 = GossipV1SummaryPreview.generate(eligibleSorted: ids, startAfter: nil)
        XCTAssertEqual(page1.preview.count, GossipV1.MAX_SUMMARY_PREVIEW_ITEMS)
        XCTAssertEqual(page1.preview, Array(ids.prefix(GossipV1.MAX_SUMMARY_PREVIEW_ITEMS)))
        XCTAssertEqual(page1.cursor, page1.preview.last)

        let page2 = GossipV1SummaryPreview.generate(eligibleSorted: ids, startAfter: page1.cursor)
        XCTAssertEqual(page2.preview, Array(ids.dropFirst(GossipV1.MAX_SUMMARY_PREVIEW_ITEMS)))
        XCTAssertNil(page2.cursor)
    }

    private func makeIDs(count: Int) throws -> [GossipV1ItemID] {
        try (0..<count).map { i in
            var bytes = Data(repeating: 0, count: 32)
            bytes[0] = UInt8(i & 0xFF)
            bytes[1] = UInt8((i >> 8) & 0xFF)
            return try GossipV1ItemID(bytes: bytes)
        }
    }

    private func makeItemID(prefix: UInt8, tail: UInt8 = 0x00) throws -> GossipV1ItemID {
        var bytes = Data(repeating: tail, count: 32)
        bytes[0] = prefix
        return try GossipV1ItemID(bytes: bytes)
    }
}
