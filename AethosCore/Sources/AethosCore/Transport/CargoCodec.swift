import Foundation

public enum CargoFragment: Equatable, Sendable {
    case metadata(type: UInt8, id: Data, bytes: Data)
    case chunkPart(id: Data, partIndex: UInt16, partCount: UInt16, bytes: Data)
}

public enum CargoCodec {
    public enum CargoCodecError: Swift.Error, Equatable {
        case invalidMaxFramePayloadBytes
        case unknownFrameType(UInt8)
        case invalidParts
        case metadataMustBeSingleFrame
        case metadataIdMismatch
    }

    // Stable frame type codes.
    public enum FrameType: UInt8, Sendable {
        case receipt = 1
        case envelope = 2
        case manifest = 3
        case chunk = 4
        case inventory = 5
        case inventoryRequest = 6
        case message = 7
    }

    public static func encode(_ item: CargoItem, maxFramePayloadBytes: Int) throws -> [Frame] {
        guard maxFramePayloadBytes > 0 else { throw CargoCodecError.invalidMaxFramePayloadBytes }

        switch item {
        case let .receipt(bytes):
            let id = AethosIDs.receiptId(canonicalBytes: bytes)
            return [Frame(type: FrameType.receipt.rawValue, id: id, partIndex: 0, partCount: 1, payload: bytes)]

        case let .envelope(bytes):
            let id = AethosIDs.envelopeId(canonicalBytes: bytes)
            return [Frame(type: FrameType.envelope.rawValue, id: id, partIndex: 0, partCount: 1, payload: bytes)]

        case let .manifest(bytes):
            let id = AethosIDs.manifestId(canonicalBytes: bytes)
            return [Frame(type: FrameType.manifest.rawValue, id: id, partIndex: 0, partCount: 1, payload: bytes)]

        case let .inventory(bytes):
            let id = AethosIDs.sha256(bytes)
            return [Frame(type: FrameType.inventory.rawValue, id: id, partIndex: 0, partCount: 1, payload: bytes)]

        case let .inventoryRequest(bytes):
            let id = AethosIDs.sha256(bytes)
            return [Frame(type: FrameType.inventoryRequest.rawValue, id: id, partIndex: 0, partCount: 1, payload: bytes)]

        case let .message(bytes):
            let id = AethosIDs.messageId(canonicalBytes: bytes)
            return [Frame(type: FrameType.message.rawValue, id: id, partIndex: 0, partCount: 1, payload: bytes)]

        case let .chunk(id, bytes):
            if bytes.isEmpty {
                return [Frame(type: FrameType.chunk.rawValue, id: id, partIndex: 0, partCount: 1, payload: Data())]
            }

            let partCount = UInt16((bytes.count + maxFramePayloadBytes - 1) / maxFramePayloadBytes)
            var frames: [Frame] = []
            frames.reserveCapacity(Int(partCount))

            var partIndex: UInt16 = 0
            var offset = 0
            while offset < bytes.count {
                let end = min(offset + maxFramePayloadBytes, bytes.count)
                let part = bytes.subdata(in: offset..<end)
                frames.append(Frame(type: FrameType.chunk.rawValue, id: id, partIndex: partIndex, partCount: partCount, payload: part))
                partIndex += 1
                offset = end
            }
            return frames
        }
    }

    public static func decode(_ frame: Frame) throws -> CargoFragment {
        guard let type = FrameType(rawValue: frame.type) else {
            throw CargoCodecError.unknownFrameType(frame.type)
        }
        guard frame.partCount > 0, frame.partIndex < frame.partCount else {
            throw CargoCodecError.invalidParts
        }

        switch type {
        case .receipt, .envelope, .manifest, .inventory, .inventoryRequest, .message:
            guard frame.partCount == 1, frame.partIndex == 0 else {
                throw CargoCodecError.metadataMustBeSingleFrame
            }

            let expectedId: Data
            switch type {
            case .receipt:
                expectedId = AethosIDs.receiptId(canonicalBytes: frame.payload)
            case .envelope:
                expectedId = AethosIDs.envelopeId(canonicalBytes: frame.payload)
            case .manifest:
                expectedId = AethosIDs.manifestId(canonicalBytes: frame.payload)
            case .inventory:
                expectedId = AethosIDs.sha256(frame.payload)
            case .inventoryRequest:
                expectedId = AethosIDs.sha256(frame.payload)
            case .message:
                expectedId = AethosIDs.messageId(canonicalBytes: frame.payload)
            case .chunk:
                expectedId = frame.id // unreachable
            }

            guard frame.id == expectedId else {
                throw CargoCodecError.metadataIdMismatch
            }
            return .metadata(type: frame.type, id: frame.id, bytes: frame.payload)

        case .chunk:
            return .chunkPart(id: frame.id, partIndex: frame.partIndex, partCount: frame.partCount, bytes: frame.payload)
        }
    }
}
