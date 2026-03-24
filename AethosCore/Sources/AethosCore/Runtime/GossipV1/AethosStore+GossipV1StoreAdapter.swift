import Foundation

extension AethosStore {
    /// Runtime-facing seam that bridges `AethosStore` persistence to the Gossip v1 encounter engine.
    ///
    /// Layering:
    /// - Composer persists protocol objects into `AethosStore`
    /// - `GossipV1EncounterEngine` reads/writes replicated objects through this adapter
    /// - `GossipV1StreamAdapter` / `GossipV1StreamSession` carry bytes across transport
    public final class GossipV1StoreAdapter: GossipV1EncounterEngine.Store {
        public enum Policy: Equatable, Sendable {
            /// Advertise only objects in the dedicated gossip object table.
            case gossipObjectsOnly

            /// Advertise both dedicated gossip objects and queued envelope outbox entries.
            ///
            /// This is useful while runtime composition still stages origin envelopes in outbox.
            case gossipObjectsAndQueuedOutboxEnvelopes
        }

        private final class StoreBox: @unchecked Sendable {
            let store: AethosStore

            init(store: AethosStore) {
                self.store = store
            }
        }

        private let storeBox: StoreBox
        private let policy: Policy

        public init(store: AethosStore, policy: Policy = .gossipObjectsOnly) {
            self.storeBox = StoreBox(store: store)
            self.policy = policy
        }

        public func eligibleItemIDs(nowMs: UInt64) throws -> [GossipV1ItemID] {
            let cutoff = nowMsPlusSkewClamped(nowMs)
            var ids = try storeBox.store.listGossipItemIDs(eligibleAfterUnixMs: cutoff)

            if policy == .gossipObjectsAndQueuedOutboxEnvelopes {
                ids.append(contentsOf: try storeBox.store.listQueuedOutboxEnvelopeItemIDs(eligibleAfterUnixMs: cutoff))
            }

            return deduplicatedSorted(ids)
        }

        public func fetch(_ itemID: GossipV1ItemID) throws -> (envelopeBytes: Data, expiryUnixMs: UInt64, hopCount: UInt16)? {
            if let object = try storeBox.store.getGossipItem(itemID: itemID.rawBytes()) {
                return (
                    envelopeBytes: object.envelopeBytes,
                    expiryUnixMs: UInt64(max(object.expiryUnixMs, 0)),
                    hopCount: UInt16(clamping: object.hopCount)
                )
            }

            guard policy == .gossipObjectsAndQueuedOutboxEnvelopes else {
                return nil
            }

            guard let envelope = try storeBox.store.getQueuedOutboxEnvelope(itemID: itemID.rawBytes()) else {
                return nil
            }
            return (envelopeBytes: envelope.payload, expiryUnixMs: envelope.expiryUnixMs, hopCount: 0)
        }

        public func existingHopCount(_ itemID: GossipV1ItemID) throws -> UInt16? {
            guard let object = try storeBox.store.getGossipItem(itemID: itemID.rawBytes()) else {
                return nil
            }
            return UInt16(clamping: object.hopCount)
        }

        public func ingest(_ itemID: GossipV1ItemID, envelopeBytes: Data, expiryUnixMs: UInt64, hopCount: UInt16) throws {
            let derived = GossipV1ItemID.derive(fromEnvelopeBytes: envelopeBytes)
            guard derived == itemID else {
                throw GossipV1FrameError.transferItemIDMismatch
            }

            if let existing = try existingHopCount(itemID), hopCount < existing {
                throw GossipV1EncounterEngine.ValidationError.hopRegression(existing: existing, incoming: hopCount)
            }

            let expiry = Int64(clamping: expiryUnixMs)
            let hop = Int64(hopCount)
            try storeBox.store.upsertGossipItem(itemID: itemID.rawBytes(), envelopeBytes: envelopeBytes, expiryUnixMs: expiry, hopCount: hop)
        }

        private func deduplicatedSorted(_ ids: [GossipV1ItemID]) -> [GossipV1ItemID] {
            let unique = Set(ids)
            return unique.sorted {
                DataLexicographic.compare($0.rawBytes(), $1.rawBytes()) == .orderedAscending
            }
        }

        private func nowMsPlusSkewClamped(_ nowMs: UInt64) -> Int64 {
            let skew = GossipV1.CLOCK_SKEW_TOLERANCE_MS
            let cutoff: UInt64
            if nowMs > UInt64.max - skew {
                cutoff = UInt64.max
            } else {
                cutoff = nowMs + skew
            }
            return Int64(min(cutoff, UInt64(Int64.max)))
        }
    }
}
