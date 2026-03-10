import Foundation
import XCTest
@testable import AethosCore

final class GossipV1FramingTests: XCTestCase {
    func testStreamEncodeDecodeRoundTrip() throws {
        let frameBytes = try makeCanonicalFrameBytes()
        let encoded = try GossipV1Framing.encodeStreamFrame(frameBytes)
        let decoded = try GossipV1Framing.decodeStreamFrame(from: encoded)
        XCTAssertEqual(decoded.frameBytes, frameBytes)
        XCTAssertEqual(decoded.bytesConsumed, encoded.count)

        let decodedSingle = try GossipV1Framing.decodeSingleStreamFrame(from: encoded)
        XCTAssertEqual(decodedSingle, frameBytes)
    }

    func testStreamMultiFrameConcatenationConsumesOneFrame() throws {
        let bytes1 = try makeCanonicalFrameBytes(seed: 0x01)
        let bytes2 = try makeCanonicalFrameBytes(seed: 0x02)

        let f1 = try GossipV1Framing.encodeStreamFrame(bytes1)
        let f2 = try GossipV1Framing.encodeStreamFrame(bytes2)
        var concatenated = Data()
        concatenated.append(f1)
        concatenated.append(f2)

        let decoded1 = try GossipV1Framing.decodeStreamFrame(from: concatenated)
        XCTAssertEqual(decoded1.frameBytes, bytes1)
        XCTAssertEqual(decoded1.bytesConsumed, f1.count)

        let remaining = concatenated.subdata(in: decoded1.bytesConsumed..<concatenated.count)
        let decoded2 = try GossipV1Framing.decodeStreamFrame(from: remaining)
        XCTAssertEqual(decoded2.frameBytes, bytes2)
        XCTAssertEqual(decoded2.bytesConsumed, f2.count)
    }

    func testStreamDecodeSingleRejectsTrailingBytes() throws {
        let bytes1 = try makeCanonicalFrameBytes(seed: 0x01)
        let bytes2 = try makeCanonicalFrameBytes(seed: 0x02)
        let f1 = try GossipV1Framing.encodeStreamFrame(bytes1)
        let f2 = try GossipV1Framing.encodeStreamFrame(bytes2)

        var concatenated = Data()
        concatenated.append(f1)
        concatenated.append(f2)

        XCTAssertThrowsError(try GossipV1Framing.decodeSingleStreamFrame(from: concatenated)) { err in
            XCTAssertEqual(
                err as? GossipV1FramingError,
                .trailingBytes(expectedConsumed: f1.count, actualBytes: f1.count + f2.count)
            )
        }
    }

    func testStreamPartialHeaderIsTruncated() {
        for n in 0..<4 {
            let data = Data(repeating: 0x00, count: n)
            XCTAssertThrowsError(try GossipV1Framing.decodeStreamFrame(from: data)) { err in
                XCTAssertEqual(err as? GossipV1FramingError, .truncated)
            }
        }
    }

    func testStreamPartialPayloadIsTruncated() throws {
        let frameBytes = try makeCanonicalFrameBytes()
        let encoded = try GossipV1Framing.encodeStreamFrame(frameBytes)
        let truncated = encoded.dropLast(1)
        XCTAssertThrowsError(try GossipV1Framing.decodeStreamFrame(from: Data(truncated))) { err in
            XCTAssertEqual(err as? GossipV1FramingError, .truncated)
        }
    }

    func testStreamDecodeWorksWithMisalignedBuffer() throws {
        let frameBytes = try makeCanonicalFrameBytes(seed: 0x33)
        let encoded = try GossipV1Framing.encodeStreamFrame(frameBytes)

        // Force a frame to start at offset 1.
        var data = Data([0xFF])
        data.append(encoded)

        let slice = data.subdata(in: 1..<data.count)
        let decoded = try GossipV1Framing.decodeSingleStreamFrame(from: slice)
        XCTAssertEqual(decoded, frameBytes)
    }

    func testStreamOversizedFrameLenRejected() {
        var out = Data()
        var tooLarge = UInt32(GossipV1.MAX_FRAME_BYTES + 1).bigEndian
        out.append(contentsOf: withUnsafeBytes(of: &tooLarge) { Data($0) })

        XCTAssertThrowsError(try GossipV1Framing.decodeStreamFrame(from: out)) { err in
            XCTAssertEqual(
                err as? GossipV1FramingError,
                .frameTooLarge(max: GossipV1.MAX_FRAME_BYTES, actual: GossipV1.MAX_FRAME_BYTES + 1)
            )
        }
    }

    func testDatagramEmptyRejected() {
        XCTAssertThrowsError(try GossipV1Framing.decodeDatagramFrame(Data())) { err in
            XCTAssertEqual(err as? GossipV1FramingError, .emptyDatagram)
        }
    }

    func testDatagramOverMaxRejected() {
        let datagram = Data(repeating: 0xEE, count: GossipV1.MAX_FRAME_BYTES + 1)
        XCTAssertThrowsError(try GossipV1Framing.decodeDatagramFrame(datagram)) { err in
            XCTAssertEqual(
                err as? GossipV1FramingError,
                .frameTooLarge(max: GossipV1.MAX_FRAME_BYTES, actual: GossipV1.MAX_FRAME_BYTES + 1)
            )
        }
    }

    func testDatagramTrailingBytesAllowedAtFramingLayer() throws {
        let frameBytes = try makeCanonicalFrameBytes()
        var datagram = frameBytes
        datagram.append(0x00)

        // Datagram framing only enforces basic size constraints; CBOR canonicality
        // and trailing-byte rejection are enforced by GossipV1Frame.decode(bytes:).
        let out = try GossipV1Framing.decodeDatagramFrame(datagram)
        XCTAssertEqual(out, datagram)

        XCTAssertThrowsError(try GossipV1Frame.decode(bytes: out))
    }
}

private extension GossipV1FramingTests {
    func makeCanonicalFrameBytes(seed: UInt8 = 0x01) throws -> Data {
        let a = try GossipV1ItemID(bytes: Data(repeating: seed, count: 32))
        let b = try GossipV1ItemID(bytes: Data(repeating: seed ^ 0xFF, count: 32))
        let request = try GossipV1RequestFrame(want: [a, b])
        return GossipV1Frame.request(request).encode()
    }
}
