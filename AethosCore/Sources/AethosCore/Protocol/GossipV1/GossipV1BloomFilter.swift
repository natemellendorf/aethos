import Foundation

/// Deterministic bloom filter builder for gossip v1.
///
/// Source of truth: `docs/protocol/encounter.md`.
public enum GossipV1BloomFilter {
    public static func build(for itemIDs: some Sequence<GossipV1ItemID>) -> Data {
        var bloom = Data(repeating: 0, count: GossipV1.BLOOM_FILTER_BYTES)
        let bitCount = GossipV1.BLOOM_FILTER_BYTES * 8

        for itemID in itemIDs {
            precondition(itemID.bytes.count == 32, "GossipV1ItemID must be 32 bytes")
            for i in 0..<GossipV1.BLOOM_HASH_COUNT {
                let digest = AethosIDs.sha256(itemID.bytes + Data([UInt8(i)]))
                let v = uint64BE(digest.prefix(8))
                let bitIndex = Int(v % UInt64(bitCount))
                let byteIndex = bitIndex / 8
                let bitOffset = bitIndex % 8 // LSB0
                bloom[byteIndex] |= (1 << bitOffset)
            }
        }

        return bloom
    }

    private static func uint64BE(_ bytes: Data.SubSequence) -> UInt64 {
        precondition(bytes.count == 8, "Expected 8 bytes for uint64")
        var v: UInt64 = 0
        for b in bytes {
            v = (v << 8) | UInt64(b)
        }
        return v
    }
}
