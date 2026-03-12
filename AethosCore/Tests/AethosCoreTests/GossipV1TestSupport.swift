import Foundation
@testable import AethosCore

/// Shared deterministic helpers for Gossip v1 tests.
///
/// Intentionally scoped to the test target.
enum GossipV1TestSupport {
    static func fixturesDir(file: StaticString = #filePath) -> URL {
        let here = URL(fileURLWithPath: "\(file)")
        return here
            .deletingLastPathComponent() // AethosCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // AethosCore
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Fixtures/Protocol/gossip-v1", isDirectory: true)
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
