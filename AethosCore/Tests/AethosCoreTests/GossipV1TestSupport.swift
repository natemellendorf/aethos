import Foundation
@testable import AethosCore

/// Shared deterministic helpers for Gossip v1 tests.
///
/// Intentionally scoped to the test target.
enum GossipV1TestSupport {
    private static let fixtureRootResourcePath = "Fixtures/Protocol/gossip-v1"

    enum FixtureError: Swift.Error, CustomStringConvertible, Equatable {
        case missingResource(relativePath: String)

        var description: String {
            switch self {
            case .missingResource(let relativePath):
                return "Missing Gossip v1 fixture resource: \(relativePath)"
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
        body: Data
    ) throws -> Data {
        try CanonicalCBOREncoder().encode(
            .map([
                .init(key: .text("to_wayfarer_id"), value: .bytes(toWayfarerId)),
                .init(key: .text("manifest_id"), value: .bytes(manifestId)),
                .init(key: .text("body"), value: .bytes(body)),
            ])
        )
    }

    static func makeTransferEnvelopeBytes(seed: UInt64) throws -> Data {
        let seedByte = UInt8(truncatingIfNeeded: seed)
        let toWayfarerId = Data(repeating: seedByte, count: 32)
        let manifestId = Data(repeating: seedByte ^ 0xFF, count: 32)
        let body = Data([seedByte, seedByte &+ 1])
        return try makeTransferEnvelopeBytes(
            toWayfarerId: toWayfarerId,
            manifestId: manifestId,
            body: body
        )
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
