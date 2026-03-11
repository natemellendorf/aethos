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

    /// Error thrown when at least one valid frame was decoded, but a later stream-boundary
    /// violation was encountered in the same `append` call.
    ///
    /// This avoids silently dropping already-decoded frames.
    public struct PartialAppendError: Swift.Error, Equatable, Sendable {
        public let frames: [Data]
        public let underlying: GossipV1FramingError

        public init(frames: [Data], underlying: GossipV1FramingError) {
            self.frames = frames
            self.underlying = underlying
        }
    }

    /// Appends raw stream bytes and returns any newly completed frames.
    ///
    /// - Throws: `GossipV1FramingError` for invalid boundaries (oversize, empty, etc.).
    public mutating func append(_ bytes: Data) throws -> [Data] {
        guard !bytes.isEmpty else { return [] }

        var frames: [Data] = []
        do {
            try decoder.appendChecked(bytes)
            while let next = try decoder.nextFrame() {
                frames.append(next)
            }
            return frames
        } catch let error as GossipV1FramingError {
            // If we already decoded frames in this call, do not drop them.
            if frames.isEmpty {
                throw error
            }
            throw PartialAppendError(frames: frames, underlying: error)
        }
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
