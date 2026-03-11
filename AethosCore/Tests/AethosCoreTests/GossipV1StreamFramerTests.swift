import Foundation
import XCTest
@testable import AethosCore

final class GossipV1StreamFramerTests: XCTestCase {
    func testPartialReads_splitLengthPrefix_thenPayload() throws {
        let frameBytes = Data([0xAA, 0xBB, 0xCC])
        let streamBytes = try GossipV1Framing.encodeStreamFrame(frameBytes)

        var framer = GossipV1StreamFramer()

        // First 2 bytes of prefix.
        let a = try framer.append(streamBytes.subdata(in: 0..<2))
        XCTAssertEqual(a, [])

        // Remaining 2 bytes of prefix.
        let b = try framer.append(streamBytes.subdata(in: 2..<4))
        XCTAssertEqual(b, [])

        // Payload.
        let c = try framer.append(streamBytes.subdata(in: 4..<streamBytes.count))
        XCTAssertEqual(c, [frameBytes])
        XCTAssertNoThrow(try framer.finish())
    }

    func testSplitPayload_acrossMultipleAppends() throws {
        let frameBytes = Data([0x10, 0x11, 0x12, 0x13, 0x14])
        let streamBytes = try GossipV1Framing.encodeStreamFrame(frameBytes)

        var framer = GossipV1StreamFramer()
        let part1 = streamBytes.subdata(in: 0..<6) // prefix + 2 payload bytes
        let part2 = streamBytes.subdata(in: 6..<streamBytes.count)

        XCTAssertEqual(try framer.append(part1), [])
        XCTAssertEqual(try framer.append(part2), [frameBytes])
        XCTAssertNoThrow(try framer.finish())
    }

    func testMultipleFramesInOneBuffer() throws {
        let f1 = Data([0x01])
        let f2 = Data([0x02, 0x03])
        var bytes = Data()
        bytes.append(try GossipV1Framing.encodeStreamFrame(f1))
        bytes.append(try GossipV1Framing.encodeStreamFrame(f2))

        var framer = GossipV1StreamFramer()
        XCTAssertEqual(try framer.append(bytes), [f1, f2])
        XCTAssertNoThrow(try framer.finish())
    }

    func testOversizeDeclaredLengthRejected() {
        var bytes = Data()
        var tooLarge = UInt32(GossipV1.MAX_FRAME_BYTES + 1).bigEndian
        bytes.append(contentsOf: withUnsafeBytes(of: &tooLarge) { Data($0) })

        var framer = GossipV1StreamFramer()
        XCTAssertThrowsError(try framer.append(bytes)) { err in
            XCTAssertEqual(
                err as? GossipV1FramingError,
                .frameTooLarge(max: GossipV1.MAX_FRAME_BYTES, actual: GossipV1.MAX_FRAME_BYTES + 1)
            )
        }
    }

    func testOversizeDeclaredLengthRejected_evenWhenPrefixArrivesSplitAcrossBuffers() throws {
        // Provide first 2 bytes of the 4-byte u32be prefix, then the rest.
        let tooLarge = UInt32(GossipV1.MAX_FRAME_BYTES + 1).bigEndian
        let prefix = withUnsafeBytes(of: tooLarge) { Data($0) }
        let part1 = prefix.prefix(2)
        let part2 = prefix.dropFirst(2)

        var framer = GossipV1StreamFramer()
        XCTAssertEqual(try framer.append(part1), [])

        do {
            _ = try framer.append(part2)
            XCTFail("Expected oversize prefix to throw")
        } catch {
            XCTAssertEqual(
                error as? GossipV1FramingError,
                .frameTooLarge(max: GossipV1.MAX_FRAME_BYTES, actual: GossipV1.MAX_FRAME_BYTES + 1)
            )
        }

        // Early rejection must not buffer the declared payload.
        XCTAssertEqual(framer.bufferedByteCount, 0)
    }

    func testTruncatedPayloadRejectedOnFinish() throws {
        let frameBytes = Data([0xAB, 0xCD])
        let streamBytes = try GossipV1Framing.encodeStreamFrame(frameBytes)

        var framer = GossipV1StreamFramer()
        // Drop last payload byte.
        _ = try framer.append(streamBytes.dropLast(1))
        XCTAssertThrowsError(try framer.finish()) { err in
            XCTAssertEqual(err as? GossipV1FramingError, .truncated)
        }
    }
}
