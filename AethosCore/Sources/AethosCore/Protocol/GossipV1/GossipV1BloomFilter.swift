import Foundation

/// Deterministic bloom filter builder for gossip v1.
///
/// Source of truth: `docs/protocol/encounter.md`.
public enum GossipV1BloomFilter {
    public static func build(for itemIDs: some Sequence<GossipV1ItemID>) -> Data {
        var bloom = Data(repeating: 0, count: GossipV1.BLOOM_FILTER_BYTES)
        let bitCount = GossipV1.BLOOM_FILTER_BYTES * 8

        // Fixed 33-byte buffer: 32 digest bytes + 1 byte index.
        // Avoids inner-loop `Data + Data` allocations while keeping the algorithm identical.
        var hashInput = Data(repeating: 0, count: 33)

        for itemID in itemIDs {
            // Copy 32 digest bytes once per item.
            hashInput.replaceSubrange(0..<32, with: itemID.bytes)
            for i in 0..<GossipV1.BLOOM_HASH_COUNT {
                hashInput[32] = UInt8(i)

                let digest = AethosIDs.sha256(hashInput)
                let v = uint64BE(digest.prefix(8))
                let bitIndex = Int(v % UInt64(bitCount))
                let byteIndex = bitIndex / 8
                let bitOffset = bitIndex % 8 // LSB0
                bloom[byteIndex] |= (UInt8(1) << bitOffset)
            }
        }

        return bloom
    }

    private static func uint64BE(_ bytes: Data.SubSequence) -> UInt64 {
        var v: UInt64 = 0
        for b in bytes {
            v = (v << 8) | UInt64(b)
        }
        return v
    }
}
