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

    func testDatagramTrailingBytesRejected() throws {
        let frameBytes = try makeCanonicalFrameBytes()
        var datagram = frameBytes
        datagram.append(0x00)

        XCTAssertThrowsError(try GossipV1Framing.decodeDatagram(datagram)) { err in
            XCTAssertEqual(err as? GossipV1FramingError, .invalidDatagramCBOR(problem: .trailingBytes))
        }
    }

    func testDatagramInvalidFrameIsWrappedAsFramingError() throws {
        // Valid canonical CBOR but not a valid frame envelope.
        let bytes = try CanonicalCBOREncoder().encode(.unsigned(1))

        XCTAssertThrowsError(try GossipV1Framing.decodeDatagram(bytes)) { err in
            XCTAssertEqual(
                err as? GossipV1FramingError,
                .invalidDatagramFrame(underlying: .envelopeNotAMap)
            )
        }
    }

    func testDatagramScalarParseErrorsAreWrappedAsFramingErrors() throws {
        // Valid canonical CBOR envelope shape, but invalid base64url in TRANSFER object.
        // This must surface as GossipV1FramingError, never GossipV1Error.
        let bytes = try CanonicalCBOREncoder().encode(
            .map([
                .init(key: .text("type"), value: .text(GossipV1FrameType.TRANSFER.rawValue)),
                .init(key: .text("payload"), value: .map([
                    .init(key: .text("objects"), value: .array([
                        .map([
                            .init(key: .text("item_id"), value: .text(String(repeating: "a", count: 64))),
                            .init(key: .text("envelope_b64"), value: .text("Zg==")),
                            .init(key: .text("expiry_unix_ms"), value: .unsigned(0)),
                            .init(key: .text("hop_count"), value: .unsigned(0)),
                        ]),
                    ])),
                ])),
            ])
        )

        XCTAssertThrowsError(try GossipV1Framing.decodeDatagram(bytes)) { err in
            guard case .invalidDatagramFrame(let underlying) = (err as? GossipV1FramingError) else {
                return XCTFail("Unexpected error: \(err)")
            }
            guard case .invalidScalar(field: let field, underlying: let scalarErr) = underlying else {
                return XCTFail("Unexpected underlying error: \(underlying)")
            }
            XCTAssertEqual(field, "envelope_b64")
            XCTAssertEqual(scalarErr, .invalidBase64URLPadding)
        }
    }

    func testDatagramDecodeReturnsParsedFrame() throws {
        let bytes = try makeCanonicalFrameBytes(seed: 0xAB)
        let frame = try GossipV1Framing.decodeDatagram(bytes)

        // If decodeDatagram returned bytes, callers would need to CBOR-decode again.
        // Instead, we return a parsed frame.
        guard case .request = frame else {
            return XCTFail("Expected request frame")
        }
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
