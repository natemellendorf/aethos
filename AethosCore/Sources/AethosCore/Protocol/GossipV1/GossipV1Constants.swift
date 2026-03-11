import Foundation

/// Gossip protocol v1 authoritative constants.
///
/// Source of truth: `docs/protocol/frames.md`.
public enum GossipV1 {
    public static let GOSSIP_VERSION: UInt64 = 1

    public static let MAX_FRAME_BYTES: Int = 1_048_576
    public static let MAX_WANT_ITEMS: Int = 256
    public static let MAX_TRANSFER_ITEMS: Int = 32
    public static let MAX_TRANSFER_BYTES: Int = 524_288

    public static let BLOOM_FILTER_BYTES: Int = 2_048
    public static let BLOOM_HASH_COUNT: Int = 4

    public static let CLOCK_SKEW_TOLERANCE_MS: UInt64 = 30_000
}
