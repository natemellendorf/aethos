import Foundation
import XCTest
@testable import AethosCore

final class GossipV1PositiveFixtureVectorsTests: XCTestCase {
    func testPositiveVectors_decodeReencodeDriftGuard_allFramesByteStable() throws {
        let vectors: [(file: String, type: GossipV1FrameType)] = [
            ("hello.cbor", .HELLO),
            ("summary.cbor", .SUMMARY),
            ("request.cbor", .REQUEST),
            ("transfer.cbor", .TRANSFER),
            ("receipt.cbor", .RECEIPT),
            ("relay_ingest.cbor", .RELAY_INGEST),
        ]

        for v in vectors {
            let fixtureBytes = try GossipV1TestSupport.fixtureData(v.file)

            let decoded = try GossipV1Frame.decode(bytes: fixtureBytes)
            XCTAssertEqual(decoded.encode(), fixtureBytes, "Fixture drift guard failed: decode->encode bytes changed for \(v.file)")

            let decodedType = try decodedFrameType(decoded)
            XCTAssertEqual(decodedType, v.type, "Fixture type mismatch for \(v.file)")
        }
    }
}

private extension GossipV1PositiveFixtureVectorsTests {
    func decodedFrameType(_ frame: GossipV1Frame) throws -> GossipV1FrameType {
        switch frame {
        case .hello:
            return .HELLO
        case .summary:
            return .SUMMARY
        case .request:
            return .REQUEST
        case .transfer:
            return .TRANSFER
        case .receipt:
            return .RECEIPT
        case .relayIngest:
            return .RELAY_INGEST
        }
    }
}
