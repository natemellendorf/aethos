import Crypto
import Foundation
@testable import AethosCore

/// Test-only utilities for producing authoritative fixture vectors.
///
/// These helpers deliberately live in the test target so production APIs stay stable.
enum GossipV1FixtureVectorBuilder {
    static func encodeEnvelopeBytes(_ value: CanonicalCBORValue) throws -> Data {
        try CanonicalCBOREncoder().encode(value)
    }

    static func encodeFrameBytes(type: GossipV1FrameType, payload: CanonicalCBORValue) throws -> Data {
        let env: CanonicalCBORValue = .map([
            .init(key: .text("type"), value: .text(type.rawValue)),
            .init(key: .text("payload"), value: payload),
        ])
        return try CanonicalCBOREncoder().encode(env)
    }

    static func sha256HexLower(_ bytes: Data) -> String {
        let digest = SHA256.hash(data: bytes)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    static func base64URLNoPadding(_ bytes: Data) -> String {
        GossipV1Base64URL.encode(bytes)
    }
}
