import Foundation

/// Stream I/O boundary handling for Gossip v1 TCP/WebSocket bearers.
///
/// This is a transport-oriented wrapper that incrementally accepts bytes and emits
/// complete Gossip v1 *frame bytes* (CBOR envelope bytes), excluding the u32be length prefix.
///
/// Boundary format: `[uint32be frame_len][frame_len bytes frameBytes]`.
public struct GossipV1StreamFramer: Sendable {
    private var decoder = GossipV1StreamFrameDecoder()

    public init() {}

    public var bufferedByteCount: Int { decoder.bufferedByteCount }

    /// Appends raw stream bytes and returns any newly completed frames.
    ///
    /// - Throws: `GossipV1FramingError` for invalid boundaries (oversize, empty, etc.).
    public mutating func append(_ bytes: Data) throws -> [Data] {
        guard !bytes.isEmpty else { return [] }
        decoder.append(bytes)

        var frames: [Data] = []
        while let next = try decoder.nextFrame() {
            frames.append(next)
        }
        return frames
    }

    /// Signals end-of-stream.
    ///
    /// If there are remaining buffered bytes, the peer truncated the stream mid-frame.
    public mutating func finish() throws {
        guard decoder.bufferedByteCount == 0 else {
            throw GossipV1FramingError.truncated
        }
    }
}
