import Foundation
@testable import AethosCore
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Shared deterministic helpers for Gossip v1 tests.
///
/// Intentionally scoped to the test target.
enum GossipV1TestSupport {
    private static let fixtureRootResourcePath = "Fixtures/Protocol/gossip-v1"

    enum FixtureError: Swift.Error, CustomStringConvertible, Equatable {
        case missingResource(relativePath: String)
        case invalidFixture(detail: String)

        var description: String {
            switch self {
            case .missingResource(let relativePath):
                return "Missing Gossip v1 fixture resource: \(relativePath)"
            case .invalidFixture(let detail):
                return "Invalid Gossip v1 fixture: \(detail)"
            }
        }
    }

    /// Minimal thread-safe box for capturing values from concurrent callbacks.
    ///
    /// Intentionally test-only; prefer `actor` in production code.
    final class Locked<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T

        init(_ value: T) {
            self.value = value
        }

        func withLock<R>(_ body: (inout T) -> R) -> R {
            lock.lock()
            defer { lock.unlock() }
            return body(&value)
        }
    }

    /// Fixture bytes loaded from SwiftPM test resources.
    ///
    /// - Parameter relativePath: Path relative to `Fixtures/Protocol/gossip-v1/`.
    static func fixtureData(_ relativePath: String) throws -> Data {
        let url = try fixtureURL(relativePath)
        return try Data(contentsOf: url)
    }

    /// Fixture URL loaded from SwiftPM test resources.
    ///
    /// - Parameter relativePath: Path relative to `Fixtures/Protocol/gossip-v1/`.
    static func fixtureURL(_ relativePath: String) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else {
            throw FixtureError.missingResource(relativePath: "\(fixtureRootResourcePath)/")
        }

        let resourcePath = "\(fixtureRootResourcePath)/\(trimmed)"
        guard let url = Bundle.module.url(forResource: resourcePath, withExtension: nil) else {
            throw FixtureError.missingResource(relativePath: resourcePath)
        }
        return url
    }

    static func makeHello(
        version: UInt64,
        pubKeyRawBytes: Data = Data(repeating: 0x01, count: 32),
        maxWant: UInt64 = 128,
        maxTransfer: UInt64 = 16
    ) throws -> GossipV1HelloFrame {
        let nodeID = GossipV1NodeID.derive(fromPublicKeyRawBytes: pubKeyRawBytes)
        return try GossipV1HelloFrame(
            version: version,
            nodeID: nodeID,
            nodePublicKeyRawBytes: pubKeyRawBytes,
            capabilities: ["store"],
            propagationClass: "direct",
            maxWant: maxWant,
            maxTransfer: maxTransfer
        )
    }

    static func makeTransferEnvelopeBytes(
        toWayfarerId: Data,
        manifestId: Data,
        body: Data,
        authorSeed: UInt64 = 0
    ) throws -> Data {
        let signingPayload = try CanonicalCBOREncoder().encode(
            .map([
                .init(key: .text("to_wayfarer_id"), value: .bytes(toWayfarerId)),
                .init(key: .text("manifest_id"), value: .bytes(manifestId)),
                .init(key: .text("body"), value: .bytes(body)),
            ])
        )
        let signingDigest = AethosIDs.sha256(Data("AETHOS_ENVELOPE_V1".utf8) + signingPayload)
        let authorPrivateKeyRaw: Data
        switch authorSeed {
        case 1:
            authorPrivateKeyRaw = Data([
                0x04, 0xB9, 0xA6, 0x48, 0xEA, 0x24, 0xFC, 0x25,
                0xF3, 0x75, 0xDB, 0x40, 0xFD, 0x9D, 0xE7, 0x2D,
                0x1B, 0x64, 0x92, 0x1D, 0xFF, 0x08, 0x02, 0x7F,
                0x65, 0x95, 0xEA, 0xB4, 0xE7, 0x34, 0x55, 0xFD,
            ])
        case 2:
            authorPrivateKeyRaw = Data([
                0xB2, 0xE7, 0x6B, 0xC1, 0xA0, 0xA3, 0xDE, 0x2F,
                0x0C, 0x46, 0x8A, 0x25, 0xA3, 0x6C, 0xE1, 0xE6,
                0x77, 0x72, 0x10, 0x9C, 0x45, 0x69, 0x10, 0xB0,
                0x71, 0xA2, 0xB2, 0x24, 0x0C, 0x0B, 0xBA, 0x0A,
            ])
        default:
            authorPrivateKeyRaw = AethosIDs.sha256(Data("AETHOS_GOSSIP_V1_AUTHOR_\(authorSeed)".utf8))
        }
        let authorPrivateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: authorPrivateKeyRaw)
        let authorPublicKey = authorPrivateKey.publicKey.rawRepresentation
        let authorSignature = try authorPrivateKey.signature(for: signingDigest)

        return try CanonicalCBOREncoder().encode(
            .map([
                .init(key: .text("to_wayfarer_id"), value: .bytes(toWayfarerId)),
                .init(key: .text("manifest_id"), value: .bytes(manifestId)),
                .init(key: .text("body"), value: .bytes(body)),
                .init(key: .text("author_pubkey"), value: .bytes(authorPublicKey)),
                .init(key: .text("author_sig"), value: .bytes(authorSignature)),
            ])
        )
    }

    static func makeTransferFixtureFrame() throws -> GossipV1TransferFrame {
        let objects = try transferFixtureObjects()
        return try GossipV1TransferFrame(objects: objects)
    }

    static func makeOversizeTransferFrameBytes() throws -> Data {
        let bodySize = GossipV1.MAX_TRANSFER_BYTES + 1024
        let body = Data(repeating: 0xAB, count: bodySize)
        let envelopeBytes = try makeTransferEnvelopeBytes(
            toWayfarerId: Data(repeating: 0xCD, count: 32),
            manifestId: Data(repeating: 0xEF, count: 32),
            body: body,
            authorSeed: 42
        )
        guard envelopeBytes.count > GossipV1.MAX_TRANSFER_BYTES else {
            throw FixtureError.invalidFixture(detail: "Oversize transfer envelope length was \(envelopeBytes.count)")
        }

        let itemID = GossipV1ItemID.derive(fromEnvelopeBytes: envelopeBytes)
        let objectValue: CanonicalCBORValue = .map([
            .init(key: .text("item_id"), value: .text(itemID.hex)),
            .init(key: .text("envelope_b64"), value: .text(GossipV1Base64URL.encode(envelopeBytes))),
            .init(key: .text("expiry_unix_ms"), value: .unsigned(4_102_444_800_000)),
            .init(key: .text("hop_count"), value: .unsigned(0)),
        ])
        let payload: CanonicalCBORValue = .map([
            .init(key: .text("objects"), value: .array([objectValue])),
        ])
        let frame: CanonicalCBORValue = .map([
            .init(key: .text("type"), value: .text(GossipV1FrameType.TRANSFER.rawValue)),
            .init(key: .text("payload"), value: payload),
        ])
        return try CanonicalCBOREncoder().encode(frame)
    }

    static func makeTransferEnvelopeBytes(seed: UInt64) throws -> Data {
        let seedByte = UInt8(truncatingIfNeeded: seed)
        let toWayfarerId = Data(repeating: seedByte, count: 32)
        let manifestId = Data(repeating: seedByte ^ 0xFF, count: 32)
        let body = Data([seedByte, seedByte &+ 1])
        return try makeTransferEnvelopeBytes(
            toWayfarerId: toWayfarerId,
            manifestId: manifestId,
            body: body,
            authorSeed: seed
        )
    }

    private static func transferFixtureObjects() throws -> [GossipV1TransferFrame.Object] {
        let data = try fixtureData("transfer.json")
        let decoded = try JSONSerialization.jsonObject(with: data)
        guard let dict = decoded as? [String: Any] else {
            throw FixtureError.invalidFixture(detail: "transfer.json is not a top-level object")
        }
        guard let rawObjects = dict["objects"] as? [[String: Any]] else {
            throw FixtureError.invalidFixture(detail: "transfer.json missing objects")
        }

        var out: [GossipV1TransferFrame.Object] = []
        out.reserveCapacity(rawObjects.count)
        for (index, object) in rawObjects.enumerated() {
            guard let itemIDHex = object["item_id"] as? String else {
                throw FixtureError.invalidFixture(detail: "transfer.json objects[\(index)].item_id")
            }
            guard let envelopeB64 = object["envelope_b64"] as? String else {
                throw FixtureError.invalidFixture(detail: "transfer.json objects[\(index)].envelope_b64")
            }
            let expiry = try requireUInt64(object["expiry_unix_ms"], field: "transfer.json objects[\(index)].expiry_unix_ms")
            let hopRaw = try requireUInt64(object["hop_count"], field: "transfer.json objects[\(index)].hop_count")
            guard hopRaw <= UInt64(UInt16.max) else {
                throw FixtureError.invalidFixture(detail: "transfer.json objects[\(index)].hop_count out of range")
            }

            let itemID = try GossipV1ItemID(hex: itemIDHex)
            let envelopeBytes = try GossipV1Base64URL.decode(envelopeB64)
            let obj = try GossipV1TransferFrame.Object(
                itemID: itemID,
                envelopeBytes: envelopeBytes,
                expiryUnixMs: expiry,
                hopCount: UInt16(hopRaw)
            )
            out.append(obj)
        }
        return out
    }

    private static func requireUInt64(_ value: Any?, field: String) throws -> UInt64 {
        guard let number = value as? NSNumber else {
            throw FixtureError.invalidFixture(detail: "\(field) not a number")
        }
        let int64 = number.int64Value
        guard int64 >= 0 else {
            throw FixtureError.invalidFixture(detail: "\(field) negative")
        }
        return UInt64(int64)
    }

    struct FixedClock: GossipV1EncounterEngine.Clock {
        let nowMs: UInt64
        func nowUnixMs() -> UInt64 { nowMs }
    }

    final class InMemoryGossipStore: @unchecked Sendable, GossipV1EncounterEngine.Store {
        struct Stored: Sendable, Equatable {
            let envelopeBytes: Data
            let expiryUnixMs: UInt64
            let hopCount: UInt16
        }

        private var storedByID: [GossipV1ItemID: Stored] = [:]
        private var eligible: [GossipV1ItemID] = []

        func eligibleItemIDs(nowMs _: UInt64) throws -> [GossipV1ItemID] { eligible }

        func fetch(_ itemID: GossipV1ItemID) throws -> (envelopeBytes: Data, expiryUnixMs: UInt64, hopCount: UInt16)? {
            guard let stored = storedByID[itemID] else { return nil }
            return (stored.envelopeBytes, stored.expiryUnixMs, stored.hopCount)
        }

        func existingHopCount(_ itemID: GossipV1ItemID) throws -> UInt16? {
            storedByID[itemID]?.hopCount
        }

        func ingest(_ itemID: GossipV1ItemID, envelopeBytes: Data, expiryUnixMs: UInt64, hopCount: UInt16) throws {
            if let existing = storedByID[itemID], hopCount < existing.hopCount {
                throw GossipV1EncounterEngine.ValidationError.hopRegression(existing: existing.hopCount, incoming: hopCount)
            }
            storedByID[itemID] = Stored(envelopeBytes: envelopeBytes, expiryUnixMs: expiryUnixMs, hopCount: hopCount)
        }

        func put(itemID: GossipV1ItemID, envelopeBytes: Data, expiryUnixMs: UInt64, hopCount: UInt16) {
            storedByID[itemID] = Stored(envelopeBytes: envelopeBytes, expiryUnixMs: expiryUnixMs, hopCount: hopCount)
        }

        func setEligible(_ ids: [GossipV1ItemID]) {
            eligible = ids
        }

        func snapshot(_ itemID: GossipV1ItemID) -> Stored? {
            storedByID[itemID]
        }
    }

    /// Deterministic chunk splitter for stream torture tests.
    ///
    /// - Parameters:
    ///   - bytes: Full byte sequence.
    ///   - sizes: Chunk sizes to repeat (e.g. [1] for byte-at-a-time).
    static func split(_ bytes: Data, repeating sizes: [Int]) -> [Data] {
        precondition(!sizes.isEmpty)
        precondition(sizes.allSatisfy { $0 > 0 })

        var out: [Data] = []
        out.reserveCapacity(max(1, bytes.count / sizes[0]))

        var i = 0
        var patternIdx = 0
        while i < bytes.count {
            let size = sizes[patternIdx % sizes.count]
            let end = min(bytes.count, i + size)
            out.append(bytes.subdata(in: i..<end))
            i = end
            patternIdx += 1
        }
        return out
    }
}
