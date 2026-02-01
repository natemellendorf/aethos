import Foundation

public enum CanonicalEncoderV1 {
    public enum TypeDiscriminator: UInt8 {
        case envelope = 1
        case manifest = 2
        case receipt = 4
    }

    public enum EnvelopeField: UInt8 {
        case toWayfarerId = 1
        case manifestId = 2
        case body = 3
    }

    public enum ManifestField: UInt8 {
        case totalSize = 1
        case chunkIds = 2
    }

    public enum ReceiptField: UInt8 {
        case envelopeId = 1
        case manifestId = 2
        case receivedAtUnixMs = 3
        case signature = 4
    }

    public static func encode(_ envelope: EnvelopeV1) -> Data {
        var out = Data()
        out.appendUInt8(envelope.version.rawValue)
        out.appendUInt8(TypeDiscriminator.envelope.rawValue)

        out.appendField(id: EnvelopeField.toWayfarerId.rawValue, raw: envelope.toWayfarerId)
        out.appendField(id: EnvelopeField.manifestId.rawValue, raw: envelope.manifestId)
        out.appendField(id: EnvelopeField.body.rawValue, raw: envelope.body)

        return out
    }

    public static func encode(_ manifest: ManifestV1) -> Data {
        var out = Data()
        out.appendUInt8(manifest.version.rawValue)
        out.appendUInt8(TypeDiscriminator.manifest.rawValue)

        var totalSizeRaw = Data()
        totalSizeRaw.appendUInt64(UInt64(manifest.totalSize))
        out.appendField(id: ManifestField.totalSize.rawValue, raw: totalSizeRaw)

        var chunkIdsRaw = Data()
        chunkIdsRaw.appendArrayOfBytes(manifest.chunkIds)
        out.appendField(id: ManifestField.chunkIds.rawValue, raw: chunkIdsRaw)

        return out
    }

    public static func encode(_ receipt: ReceiptV1) -> Data {
        var out = Data()
        out.appendUInt8(receipt.version.rawValue)
        out.appendUInt8(TypeDiscriminator.receipt.rawValue)

        out.appendField(id: ReceiptField.envelopeId.rawValue, raw: receipt.envelopeId)
        out.appendField(id: ReceiptField.manifestId.rawValue, raw: receipt.manifestId)

        var tsRaw = Data()
        tsRaw.appendUInt64(receipt.receivedAtUnixMs)
        out.appendField(id: ReceiptField.receivedAtUnixMs.rawValue, raw: tsRaw)

        out.appendOptionalField(id: ReceiptField.signature.rawValue, raw: receipt.signature)
        return out
    }
}

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

    mutating func appendOptionalField(id: UInt8, raw: Data?) {
        appendUInt8(id)
        appendUInt32(UInt32(raw?.count ?? 0))
        if let raw {
            append(raw)
        }
    }

    mutating func appendArrayOfBytes(_ items: [Data]) {
        appendUInt32(UInt32(items.count))
        for item in items {
            appendUInt32(UInt32(item.count))
            append(item)
        }
    }
}
