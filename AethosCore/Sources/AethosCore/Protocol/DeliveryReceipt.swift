import Foundation

/// A delivery receipt signed by the destination device.
/// This allows senders to verify "delivered to destination device" without trusting relays.
///
/// The receipt is signed using the destination's identity key (Curve25519/Ed25519).
/// Canonical bytes for signing exclude the signature field itself.
public struct DeliveryReceipt: Codable, Equatable, Sendable {
    /// Unique identifier for the message/transfer being acknowledged.
    public let messageId: Data

    /// The destination's wayfarer identifier (hex-encoded string for protocol use).
    public let destinationWayfarerId: String

    /// Timestamp when the destination received the message.
    public let receivedAt: Date

    /// Signature over canonical bytes, created by destination's identity key.
    public let signature: Data?

    public init(
        messageId: Data,
        destinationWayfarerId: String,
        receivedAt: Date,
        signature: Data? = nil
    ) {
        self.messageId = messageId
        self.destinationWayfarerId = destinationWayfarerId
        self.receivedAt = receivedAt
        self.signature = signature
    }
}

// MARK: - Canonical Encoding

public enum DeliveryReceiptEncoder {
    public enum Field: UInt8 {
        case messageId = 1
        case destinationWayfarerId = 2
        case receivedAtUnixMs = 3
    }

    /// Encode receipt for transport (includes signature if present).
    public static func encode(_ receipt: DeliveryReceipt) -> Data {
        var out = Data()
        out.appendUInt8(ProtocolVersion.v1.rawValue)
        out.append(0x07) // type discriminator for delivery receipt

        out.appendField(id: Field.messageId.rawValue, raw: receipt.messageId)

        let wayfarerIdData = Data(receipt.destinationWayfarerId.utf8)
        out.appendField(id: Field.destinationWayfarerId.rawValue, raw: wayfarerIdData)

        var tsRaw = Data()
        tsRaw.appendUInt64(UInt64(receipt.receivedAt.timeIntervalSince1970 * 1000))
        out.appendField(id: Field.receivedAtUnixMs.rawValue, raw: tsRaw)

        if let sig = receipt.signature {
            out.appendField(id: 0x04, raw: sig) // reuse signature field ID from ReceiptV1
        }

        return out
    }

    /// Encode canonical bytes for signing (excludes signature).
    /// This is deterministic and stable for verification.
    public static func canonicalBytes(for receipt: DeliveryReceipt) -> Data {
        var out = Data()
        out.appendUInt8(ProtocolVersion.v1.rawValue)
        out.append(0x07) // type discriminator for delivery receipt

        out.appendField(id: Field.messageId.rawValue, raw: receipt.messageId)

        let wayfarerIdData = Data(receipt.destinationWayfarerId.utf8)
        out.appendField(id: Field.destinationWayfarerId.rawValue, raw: wayfarerIdData)

        var tsRaw = Data()
        tsRaw.appendUInt64(UInt64(receipt.receivedAt.timeIntervalSince1970 * 1000))
        out.appendField(id: Field.receivedAtUnixMs.rawValue, raw: tsRaw)

        return out
    }

    /// Decode from canonical/transport bytes.
    public static func decode(_ data: Data) throws -> DeliveryReceipt {
        var r = CanonicalDecoder(data)

        guard let version = r.readUInt8(),
              let _ = ProtocolVersion(rawValue: version),
              let type = r.readUInt8(),
              type == 0x07
        else {
            throw DecodeError.invalidFormat
        }

        var messageId: Data?
        var destinationWayfarerId: String?
        var receivedAt: Date?
        var signature: Data?

        while !r.isAtEnd {
            guard let fieldId = r.readUInt8() else { break }
            guard let fieldLen = r.readUInt32() else { throw DecodeError.truncated }
            guard let fieldData = r.readData(count: Int(fieldLen)) else { throw DecodeError.truncated }

            switch fieldId {
            case Field.messageId.rawValue:
                messageId = fieldData
            case Field.destinationWayfarerId.rawValue:
                destinationWayfarerId = String(data: fieldData, encoding: .utf8)
            case Field.receivedAtUnixMs.rawValue:
                if fieldData.count == 8 {
                    let ms = fieldData.withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
                    receivedAt = Date(timeIntervalSince1970: Double(ms) / 1000.0)
                }
            case 0x04: // signature field
                signature = fieldData
            default:
                break
            }
        }

        guard let msgId = messageId,
              let wayfarerId = destinationWayfarerId,
              let ts = receivedAt
        else {
            throw DecodeError.missingRequiredField
        }

        return DeliveryReceipt(
            messageId: msgId,
            destinationWayfarerId: wayfarerId,
            receivedAt: ts,
            signature: signature
        )
    }

    public enum DecodeError: Error, Equatable {
        case invalidFormat
        case truncated
        case missingRequiredField
    }
}

// MARK: - Data Extension

private extension Data {
    mutating func appendUInt8(_ value: UInt8) {
        append(value)
    }

    mutating func appendUInt32(_ value: UInt32) {
        var v = value.bigEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func appendUInt64(_ value: UInt64) {
        var v = value.bigEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func appendField(id: UInt8, raw: Data) {
        appendUInt8(id)
        appendUInt32(UInt32(raw.count))
        append(raw)
    }
}

// MARK: - Canonical Decoder

private struct CanonicalDecoder {
    private let data: Data
    private var offset: Int = 0

    init(_ data: Data) {
        self.data = data
    }

    var isAtEnd: Bool { offset >= data.count }

    mutating func readUInt8() -> UInt8? {
        guard offset + 1 <= data.count else { return nil }
        let v = data[offset]
        offset += 1
        return v
    }

    mutating func readUInt32() -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        var v: UInt32 = 0
        for i in 0..<4 {
            v = (v << 8) | UInt32(data[offset + i])
        }
        offset += 4
        return v
    }

    mutating func readData(count: Int) -> Data? {
        guard count >= 0, offset + count <= data.count else { return nil }
        let slice = data[offset..<offset + count]
        offset += count
        return Data(slice)
    }
}
