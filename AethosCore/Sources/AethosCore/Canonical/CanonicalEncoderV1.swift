import Foundation

public enum CanonicalEncoderV1 {
    public enum TypeDiscriminator: UInt8 {
        case envelope = 1
        case manifest = 2
        case message = 3
        case receipt = 4
        case inventory = 5
        case inventoryRequest = 6
    }

    public enum MessageField: UInt8 {
        case createdAtUnixMs = 1
        case body = 2
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

    public enum InventoryField: UInt8 {
        case manifests = 1
        case generatedAtUnixMs = 2
    }

    public enum InventoryRequestField: UInt8 {
        case want = 1
    }

    /// Key type tag for canonical public identity encoding.
    public enum KeyTypeTag: UInt8 {
        case ed25519 = 1
    }

    public enum PublicIdentityField: UInt8 {
        case signingPublicKey = 1
        case exchangePublicKey = 2
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

    public static func encode(_ message: MessageV1) -> Data {
        var out = Data()
        out.appendUInt8(message.version.rawValue)
        out.appendUInt8(TypeDiscriminator.message.rawValue)

        var tsRaw = Data()
        tsRaw.appendInt64(message.createdAtUnixMs)
        out.appendField(id: MessageField.createdAtUnixMs.rawValue, raw: tsRaw)

        out.appendField(id: MessageField.body.rawValue, raw: message.body)
        return out
    }

    public static func encode(_ inventory: InventoryV1) -> Data {
        var out = Data()
        out.appendUInt8(inventory.version.rawValue)
        out.appendUInt8(TypeDiscriminator.inventory.rawValue)

        var manifestsRaw = Data()
        manifestsRaw.appendArrayOfStrings(inventory.manifests)
        out.appendField(id: InventoryField.manifests.rawValue, raw: manifestsRaw)

        var tsRaw = Data()
        tsRaw.appendInt64(inventory.generatedAtUnixMs)
        out.appendField(id: InventoryField.generatedAtUnixMs.rawValue, raw: tsRaw)

        return out
    }

    public static func encode(_ request: InventoryRequestV1) -> Data {
        var out = Data()
        out.appendUInt8(request.version.rawValue)
        out.appendUInt8(TypeDiscriminator.inventoryRequest.rawValue)

        var wantRaw = Data()
        wantRaw.appendArrayOfStrings(request.want)
        out.appendField(id: InventoryRequestField.want.rawValue, raw: wantRaw)

        return out
    }

    /// Encode the public portion of an identity into canonical bytes.
    /// Format: [version:1][keyTypeTag:1][field signingPub][field exchangePub]
    /// Deterministic and stable for use in verification and wire protocols.
    public static func encodePublicIdentity(_ identity: IdentityV1) -> Data {
        var out = Data()
        out.appendUInt8(ProtocolVersion.v1.rawValue)
        out.appendUInt8(KeyTypeTag.ed25519.rawValue)

        out.appendField(id: PublicIdentityField.signingPublicKey.rawValue, raw: identity.signingPublicKey)
        out.appendField(id: PublicIdentityField.exchangePublicKey.rawValue, raw: identity.exchangePublicKey)

        return out
    }

    /// Decode canonical public identity bytes back into components.
    public static func decodePublicIdentity(canonical: Data) throws -> (keyTypeTag: UInt8, signingPublicKey: Data, exchangePublicKey: Data) {
        var r = CanonicalDecoderReader(canonical)
        guard let _ = r.readUInt8(), // version
              let keyTypeTag = r.readUInt8()
        else {
            throw CanonicalDecoderError.invalidType
        }

        var signingPub = Data()
        var exchangePub = Data()

        while !r.isAtEnd {
            guard let fid = r.readUInt8() else { break }
            guard let len = r.readUInt32() else { throw CanonicalDecoderError.truncated }
            guard let raw = r.readData(count: Int(len)) else { throw CanonicalDecoderError.truncated }

            switch fid {
            case PublicIdentityField.signingPublicKey.rawValue:
                signingPub = raw
            case PublicIdentityField.exchangePublicKey.rawValue:
                exchangePub = raw
            default:
                break
            }
        }

        return (keyTypeTag, signingPub, exchangePub)
    }

    public static func decodeInventory(canonical: Data) throws -> InventoryV1 {
        var r = CanonicalDecoderReader(canonical)
        guard let version = r.readUInt8(),
              let type = r.readUInt8(),
              type == TypeDiscriminator.inventory.rawValue
        else {
            throw CanonicalDecoderError.invalidType
        }
        guard let pv = ProtocolVersion(rawValue: version) else {
            throw CanonicalDecoderError.invalidType
        }

        var manifests: [String] = []
        var generatedAtUnixMs: Int64 = 0

        while !r.isAtEnd {
            guard let fid = r.readUInt8() else { break }
            guard let len = r.readUInt32() else { throw CanonicalDecoderError.truncated }
            guard let raw = r.readData(count: Int(len)) else { throw CanonicalDecoderError.truncated }

            switch fid {
            case InventoryField.manifests.rawValue:
                manifests = try parseStringArray(raw)
            case InventoryField.generatedAtUnixMs.rawValue:
                if raw.count == 8 { generatedAtUnixMs = readInt64BE(raw) }
            default:
                break
            }
        }

        return InventoryV1(version: pv, manifests: manifests, generatedAtUnixMs: generatedAtUnixMs)
    }

    public static func decodeInventoryRequest(canonical: Data) throws -> InventoryRequestV1 {
        var r = CanonicalDecoderReader(canonical)
        guard let version = r.readUInt8(),
              let type = r.readUInt8(),
              type == TypeDiscriminator.inventoryRequest.rawValue
        else {
            throw CanonicalDecoderError.invalidType
        }
        guard let pv = ProtocolVersion(rawValue: version) else {
            throw CanonicalDecoderError.invalidType
        }

        var want: [String] = []

        while !r.isAtEnd {
            guard let fid = r.readUInt8() else { break }
            guard let len = r.readUInt32() else { throw CanonicalDecoderError.truncated }
            guard let raw = r.readData(count: Int(len)) else { throw CanonicalDecoderError.truncated }

            switch fid {
            case InventoryRequestField.want.rawValue:
                want = try parseStringArray(raw)
            default:
                break
            }
        }

        return InventoryRequestV1(version: pv, want: want)
    }

    public static func decodeMessage(canonical: Data) throws -> MessageV1 {
        var r = CanonicalDecoderReader(canonical)
        guard let version = r.readUInt8(),
              let type = r.readUInt8(),
              type == TypeDiscriminator.message.rawValue
        else {
            throw CanonicalDecoderError.invalidType
        }
        guard let pv = ProtocolVersion(rawValue: version) else {
            throw CanonicalDecoderError.invalidType
        }

        var createdAtUnixMs: Int64 = 0
        var body = Data()

        while !r.isAtEnd {
            guard let fid = r.readUInt8() else { break }
            guard let len = r.readUInt32() else { throw CanonicalDecoderError.truncated }
            guard let raw = r.readData(count: Int(len)) else { throw CanonicalDecoderError.truncated }

            switch fid {
            case MessageField.createdAtUnixMs.rawValue:
                if raw.count == 8 { createdAtUnixMs = readInt64BE(raw) }
            case MessageField.body.rawValue:
                body = raw
            default:
                break
            }
        }

        return MessageV1(version: pv, createdAtUnixMs: createdAtUnixMs, body: body)
    }

    public enum CanonicalDecoderError: Swift.Error, Equatable {
        case invalidType
        case truncated
    }

    private static func parseStringArray(_ raw: Data) throws -> [String] {
        var r = CanonicalDecoderReader(raw)
        guard let count = r.readUInt32() else { return [] }
        var out: [String] = []
        out.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let len = r.readUInt32() else { throw CanonicalDecoderError.truncated }
            guard let bytes = r.readData(count: Int(len)) else { throw CanonicalDecoderError.truncated }
            guard let s = String(data: bytes, encoding: .utf8) else { throw CanonicalDecoderError.truncated }
            out.append(s)
        }
        return out
    }

    private static func readInt64BE(_ data: Data) -> Int64 {
        var v: Int64 = 0
        for b in data.prefix(8) {
            v = (v << 8) | Int64(b)
        }
        return v
    }

    private struct CanonicalDecoderReader {
        private let data: Data
        private var offset: Int = 0

        init(_ data: Data) { self.data = data }
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

    mutating func appendArrayOfStrings(_ items: [String]) {
        appendUInt32(UInt32(items.count))
        for item in items {
            let utf8 = Data(item.utf8)
            appendUInt32(UInt32(utf8.count))
            append(utf8)
        }
    }

    mutating func appendInt64(_ value: Int64) {
        var v = value.bigEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
