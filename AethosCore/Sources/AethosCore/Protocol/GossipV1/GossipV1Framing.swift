import Foundation

/// Bearer framing utilities for Gossip v1.
///
/// Spec source of truth: `docs/protocol/frames.md`.
public enum GossipV1Framing {
    private static func decodeDatagramValue(_ datagram: Data) throws -> CanonicalCBORValue {
        guard !datagram.isEmpty else { throw GossipV1FramingError.emptyDatagram }
        guard datagram.count <= GossipV1.MAX_FRAME_BYTES else {
            throw GossipV1FramingError.frameTooLarge(max: GossipV1.MAX_FRAME_BYTES, actual: datagram.count)
        }

        do {
            // Enforce datagram invariant: exactly one CBOR item (the frame envelope) with no trailing bytes.
            // CanonicalCBORDecoder.decode(_:) is strict and throws on trailing bytes.
            return try CanonicalCBORDecoder().decode(datagram)
        } catch let err as CanonicalCBORDecoder.Error {
            // Normalize CBOR decoder failures to a single framing error domain.
            throw GossipV1FramingError.invalidDatagramCBOR(problem: .from(err))
        }
    }

    /// Encodes a single frame for stream bearers as:
    /// `[uint32be frame_len][frame_len bytes frameBytes]`.
    public static func encodeStreamFrame(_ frameBytes: Data) throws -> Data {
        guard !frameBytes.isEmpty else { throw GossipV1FramingError.emptyFrame }
        guard frameBytes.count <= GossipV1.MAX_FRAME_BYTES else {
            throw GossipV1FramingError.frameTooLarge(max: GossipV1.MAX_FRAME_BYTES, actual: frameBytes.count)
        }
        guard frameBytes.count <= Int(UInt32.max) else {
            throw GossipV1FramingError.frameTooLarge(max: Int(UInt32.max), actual: frameBytes.count)
        }

        var out = Data()
        out.reserveCapacity(4 + frameBytes.count)
        out.appendUInt32BE(UInt32(frameBytes.count))
        out.append(frameBytes)
        return out
    }

    /// Decodes the first stream frame from `data`.
    ///
    /// - Returns: The frame bytes and the number of bytes consumed from `data`.
    /// - Throws: `truncated` if `data` does not yet contain a complete frame.
    public static func decodeStreamFrame(from data: Data) throws -> (frameBytes: Data, bytesConsumed: Int) {
        guard data.count >= 4 else { throw GossipV1FramingError.truncated }

        let declaredLength = Int(data.readUInt32BE(at: 0))
        guard declaredLength > 0 else { throw GossipV1FramingError.emptyFrame }
        guard declaredLength <= GossipV1.MAX_FRAME_BYTES else {
            throw GossipV1FramingError.frameTooLarge(max: GossipV1.MAX_FRAME_BYTES, actual: declaredLength)
        }

        let total = 4 + declaredLength
        guard data.count >= total else { throw GossipV1FramingError.truncated }

        let frameBytes = data.subdata(in: 4..<total)
        return (frameBytes: frameBytes, bytesConsumed: total)
    }

    /// Decodes a single stream frame and requires the input to contain exactly one frame.
    public static func decodeSingleStreamFrame(from data: Data) throws -> Data {
        let decoded = try decodeStreamFrame(from: data)
        guard decoded.bytesConsumed == data.count else {
            throw GossipV1FramingError.trailingBytes(expectedConsumed: decoded.bytesConsumed, actualBytes: data.count)
        }
        return decoded.frameBytes
    }

    /// Decodes a single frame from a datagram bearer.
    ///
    /// Datagram bearers MUST carry exactly one complete frame per datagram.
    public static func decodeDatagramFrame(_ datagram: Data) throws -> Data {
        _ = try decodeDatagramValue(datagram)
        return datagram
    }

    /// Decodes and parses a single Gossip v1 frame from a datagram bearer.
    ///
    /// This enforces the datagram invariant (exactly one complete frame per datagram)
    /// and performs CBOR decoding exactly once.
    public static func decodeDatagram(_ datagram: Data) throws -> GossipV1Frame {
        let decodedValue = try decodeDatagramValue(datagram)
        return try GossipV1Frame.decode(decodedValue: decodedValue)
    }
}

public enum GossipV1DatagramCBORProblem: Equatable, Sendable {
    case truncated
    case trailingBytes
    case unsupportedMajorType(UInt8)
    case unsupportedSimpleValue(UInt8)
    case invalidAdditionalInfo(UInt8)
    case lengthTooLarge
    case bytesTooLarge(max: Int, actual: Int)
    case collectionTooLarge
    case nestingTooDeep
    case floatsNotSupported
    case indefiniteLengthNotSupported
    case nonCanonicalIntegerEncoding
    case nonCanonicalLengthEncoding
    case invalidUTF8
    case duplicateMapKey
    case nonCanonicalMapKeyOrder

    static func from(_ err: CanonicalCBORDecoder.Error) -> GossipV1DatagramCBORProblem {
        switch err {
        case .truncated:
            return .truncated
        case .trailingBytes:
            return .trailingBytes
        case .unsupportedMajorType(let v):
            return .unsupportedMajorType(v)
        case .unsupportedSimpleValue(let v):
            return .unsupportedSimpleValue(v)
        case .invalidAdditionalInfo(let v):
            return .invalidAdditionalInfo(v)
        case .lengthTooLarge:
            return .lengthTooLarge
        case .bytesTooLarge(let max, let actual):
            return .bytesTooLarge(max: max, actual: actual)
        case .collectionTooLarge:
            return .collectionTooLarge
        case .nestingTooDeep:
            return .nestingTooDeep
        case .floatsNotSupported:
            return .floatsNotSupported
        case .indefiniteLengthNotSupported:
            return .indefiniteLengthNotSupported
        case .nonCanonicalIntegerEncoding:
            return .nonCanonicalIntegerEncoding
        case .nonCanonicalLengthEncoding:
            return .nonCanonicalLengthEncoding
        case .invalidUTF8:
            return .invalidUTF8
        case .duplicateMapKey:
            return .duplicateMapKey
        case .nonCanonicalMapKeyOrder:
            return .nonCanonicalMapKeyOrder
        }
    }
}

public enum GossipV1FramingError: Swift.Error, Equatable, Sendable {
    case truncated
    case trailingBytes(expectedConsumed: Int, actualBytes: Int)
    case frameTooLarge(max: Int, actual: Int)
    case emptyFrame
    case emptyDatagram
    case invalidDatagramCBOR(problem: GossipV1DatagramCBORProblem)
}

// MARK: - Internal byte helpers

private extension Data {
    mutating func appendUInt32BE(_ v: UInt32) {
        var be = v.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }

    func readUInt32BE(at offset: Int) -> UInt32 {
        precondition(offset >= 0)
        precondition(count >= offset + 4)

        // Assemble bytes explicitly to avoid unaligned loads.
        let b0 = UInt32(self[offset])
        let b1 = UInt32(self[offset + 1])
        let b2 = UInt32(self[offset + 2])
        let b3 = UInt32(self[offset + 3])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }
}

/// Incremental stream decoder suitable for WebSocket/TCP.
public struct GossipV1StreamFrameDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    public var bufferedByteCount: Int { buffer.count }

    public mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// Returns the next available frame, or nil if more bytes are required.
    public mutating func nextFrame() throws -> Data? {
        do {
            let (frameBytes, bytesConsumed) = try GossipV1Framing.decodeStreamFrame(from: buffer)
            buffer.removeSubrange(0..<bytesConsumed)
            return frameBytes
        } catch let err as GossipV1FramingError {
            if err == .truncated { return nil }
            throw err
        }
    }
}
