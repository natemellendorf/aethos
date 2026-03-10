import Foundation

// MARK: - Frame types

public enum GossipV1FrameType: String, Sendable {
    case HELLO
    case SUMMARY
    case REQUEST
    case TRANSFER
    case RECEIPT
    case RELAY_INGEST
}

public enum GossipV1FrameError: Swift.Error, Equatable, Sendable {
    case frameTooLarge(max: Int, actual: Int)

    case envelopeNotAMap
    case envelopeMissingKey(String)
    case envelopeTypeNotText
    case envelopePayloadNotMap
    case unknownFrameType(String)

    case payloadKeysMismatch(expected: [String], actual: [String])

    case invalidVersion(expected: UInt64, actual: UInt64)
    case invalidNodePubKeyByteCount(expected: Int, actual: Int)
    case nodeIDMismatch
    case invalidRange(field: String)

    case wantTooManyItems(max: Int, actual: Int)
    case transferTooManyObjects(max: Int, actual: Int)
    case transferTotalEnvelopeBytesTooLarge(max: Int, actual: Int)
    case transferEnvelopeNotCanonical
    case transferItemIDMismatch
    case transferExpiredObject

    case duplicateItemID
    case invalidScalar(field: String)
}

// MARK: - Frames

public enum GossipV1Frame: Equatable, Sendable {
    case hello(GossipV1HelloFrame)
    case summary(GossipV1SummaryFrame)
    case request(GossipV1RequestFrame)
    case transfer(GossipV1TransferFrame)
    case receipt(GossipV1ReceiptFrame)
    case relayIngest(GossipV1RelayIngestFrame)

    public func encode() -> Data {
        switch self {
        case .hello(let f): return f.encode()
        case .summary(let f): return f.encode()
        case .request(let f): return f.encode()
        case .transfer(let f): return f.encode()
        case .receipt(let f): return f.encode()
        case .relayIngest(let f): return f.encode()
        }
    }

    public static func decode(bytes: Data) throws -> GossipV1Frame {
        if bytes.count > GossipV1.MAX_FRAME_BYTES {
            throw GossipV1FrameError.frameTooLarge(max: GossipV1.MAX_FRAME_BYTES, actual: bytes.count)
        }

        let env = try GossipV1DecodedEnvelope.decode(bytes: bytes)

        switch env.type {
        case .HELLO:
            return .hello(try GossipV1HelloFrame.decodePayload(env.payload))
        case .SUMMARY:
            return .summary(try GossipV1SummaryFrame.decodePayload(env.payload))
        case .REQUEST:
            return .request(try GossipV1RequestFrame.decodePayload(env.payload))
        case .TRANSFER:
            return .transfer(try GossipV1TransferFrame.decodePayload(env.payload))
        case .RECEIPT:
            return .receipt(try GossipV1ReceiptFrame.decodePayload(env.payload))
        case .RELAY_INGEST:
            return .relayIngest(try GossipV1RelayIngestFrame.decodePayload(env.payload))
        }
    }
}

public struct GossipV1HelloFrame: Equatable, Sendable {
    public let version: UInt64
    public let nodeID: GossipV1NodeID
    public let nodePublicKeyRawBytes: Data
    public let capabilities: [String]
    public let propagationClass: String
    public let maxWant: UInt64
    public let maxTransfer: UInt64

    public var nodePublicKeyBase64URL: String {
        GossipV1Base64URL.encode(nodePublicKeyRawBytes)
    }

    public init(
        version: UInt64,
        nodeID: GossipV1NodeID,
        nodePublicKeyRawBytes: Data,
        capabilities: [String],
        propagationClass: String,
        maxWant: UInt64,
        maxTransfer: UInt64
    ) throws {
        guard version == GossipV1.GOSSIP_VERSION else {
            throw GossipV1FrameError.invalidVersion(expected: GossipV1.GOSSIP_VERSION, actual: version)
        }
        guard nodePublicKeyRawBytes.count == 32 else {
            throw GossipV1FrameError.invalidNodePubKeyByteCount(expected: 32, actual: nodePublicKeyRawBytes.count)
        }
        let expectedNodeID = GossipV1NodeID.derive(fromPublicKeyRawBytes: nodePublicKeyRawBytes)
        guard nodeID == expectedNodeID else {
            throw GossipV1FrameError.nodeIDMismatch
        }
        guard (1...UInt64(GossipV1.MAX_WANT_ITEMS)).contains(maxWant) else {
            throw GossipV1FrameError.invalidRange(field: "max_want")
        }
        guard (1...UInt64(GossipV1.MAX_TRANSFER_ITEMS)).contains(maxTransfer) else {
            throw GossipV1FrameError.invalidRange(field: "max_transfer")
        }

        self.version = version
        self.nodeID = nodeID
        self.nodePublicKeyRawBytes = nodePublicKeyRawBytes
        self.capabilities = capabilities
        self.propagationClass = propagationClass
        self.maxWant = maxWant
        self.maxTransfer = maxTransfer
    }

    public func encode() -> Data {
        GossipV1CBOR.encodeEnvelope(type: .HELLO, payload: payloadCBOR())
    }
}

public struct GossipV1SummaryFrame: Equatable, Sendable {
    public let bloomFilter: Data
    public let itemCount: UInt64

    public init(bloomFilter: Data, itemCount: UInt64) throws {
        guard bloomFilter.count == GossipV1.BLOOM_FILTER_BYTES else {
            throw GossipV1Error.invalidBloomByteCount(expected: GossipV1.BLOOM_FILTER_BYTES, actual: bloomFilter.count)
        }
        self.bloomFilter = bloomFilter
        self.itemCount = itemCount
    }

    public func encode() -> Data {
        GossipV1CBOR.encodeEnvelope(type: .SUMMARY, payload: payloadCBOR())
    }
}

public struct GossipV1RequestFrame: Equatable, Sendable {
    public let want: [GossipV1ItemID]

    public init(want: [GossipV1ItemID]) throws {
        guard want.count <= GossipV1.MAX_WANT_ITEMS else {
            throw GossipV1FrameError.wantTooManyItems(max: GossipV1.MAX_WANT_ITEMS, actual: want.count)
        }
        guard Set(want).count == want.count else {
            throw GossipV1FrameError.duplicateItemID
        }
        self.want = want
    }

    public func encode() -> Data {
        GossipV1CBOR.encodeEnvelope(type: .REQUEST, payload: payloadCBOR())
    }
}

public struct GossipV1TransferFrame: Equatable, Sendable {
    public struct Object: Equatable, Sendable {
        public let itemID: GossipV1ItemID
        public let envelopeBytes: Data
        public let expiryUnixMs: UInt64
        public let hopCount: UInt16

        public var envelopeBase64URL: String {
            GossipV1Base64URL.encode(envelopeBytes)
        }

        public init(itemID: GossipV1ItemID, envelopeBytes: Data, expiryUnixMs: UInt64, hopCount: UInt16) throws {
            let expectedID = GossipV1ItemID.derive(fromEnvelopeBytes: envelopeBytes)
            guard itemID == expectedID else {
                throw GossipV1FrameError.transferItemIDMismatch
            }
            guard GossipV1TransferFrame.isCanonicalCBORBytes(envelopeBytes) else {
                throw GossipV1FrameError.transferEnvelopeNotCanonical
            }
            self.itemID = itemID
            self.envelopeBytes = envelopeBytes
            self.expiryUnixMs = expiryUnixMs
            self.hopCount = hopCount
        }
    }

    public let objects: [Object]

    public init(objects: [Object]) throws {
        guard objects.count <= GossipV1.MAX_TRANSFER_ITEMS else {
            throw GossipV1FrameError.transferTooManyObjects(max: GossipV1.MAX_TRANSFER_ITEMS, actual: objects.count)
        }
        let ids = objects.map { $0.itemID }
        guard Set(ids).count == ids.count else {
            throw GossipV1FrameError.duplicateItemID
        }
        self.objects = objects
    }

    public func encode() -> Data {
        GossipV1CBOR.encodeEnvelope(type: .TRANSFER, payload: payloadCBOR())
    }
}

public struct GossipV1ReceiptFrame: Equatable, Sendable {
    public let received: [GossipV1ItemID]

    public init(received: [GossipV1ItemID]) throws {
        guard Set(received).count == received.count else {
            throw GossipV1FrameError.duplicateItemID
        }
        self.received = received
    }

    public func encode() -> Data {
        GossipV1CBOR.encodeEnvelope(type: .RECEIPT, payload: payloadCBOR())
    }
}

public struct GossipV1RelayIngestFrame: Equatable, Sendable {
    public let itemIDs: [GossipV1ItemID]

    public init(itemIDs: [GossipV1ItemID]) throws {
        guard Set(itemIDs).count == itemIDs.count else {
            throw GossipV1FrameError.duplicateItemID
        }
        self.itemIDs = itemIDs
    }

    public func encode() -> Data {
        GossipV1CBOR.encodeEnvelope(type: .RELAY_INGEST, payload: payloadCBOR())
    }
}

// MARK: - Internal CBOR wiring

/// Internal representation of a decoded frame envelope.
///
/// Unknown top-level keys are preserved for forward compatibility.
internal struct GossipV1DecodedEnvelope: Equatable, Sendable {
    let type: GossipV1FrameType
    let payload: CanonicalCBORValue
    let unknownTopLevel: [String: CanonicalCBORValue]

    static func decode(bytes: Data) throws -> GossipV1DecodedEnvelope {
        let decoded = try CanonicalCBORDecoder().decode(bytes)
        guard case .map(let entries) = decoded else { throw GossipV1FrameError.envelopeNotAMap }
        let dict = GossipV1CBOR.envelopeTextKeyedMapIgnoringNonTextKeys(entries)

        guard let typeValue = dict["type"] else { throw GossipV1FrameError.envelopeMissingKey("type") }
        guard let payloadValue = dict["payload"] else { throw GossipV1FrameError.envelopeMissingKey("payload") }

        guard case .text(let typeString) = typeValue else { throw GossipV1FrameError.envelopeTypeNotText }
        guard case .map = payloadValue else { throw GossipV1FrameError.envelopePayloadNotMap }
        guard let type = GossipV1FrameType(rawValue: typeString) else { throw GossipV1FrameError.unknownFrameType(typeString) }

        var unknown: [String: CanonicalCBORValue] = [:]
        unknown.reserveCapacity(max(0, dict.count - 2))
        for (k, v) in dict where k != "type" && k != "payload" {
            unknown[k] = v
        }

        return GossipV1DecodedEnvelope(type: type, payload: payloadValue, unknownTopLevel: unknown)
    }
}

internal enum GossipV1CBOR {
    static func encodeEnvelope(type: GossipV1FrameType, payload: CanonicalCBORValue) -> Data {
        let env: CanonicalCBORValue = .map([
            .init(key: .text("type"), value: .text(type.rawValue)),
            .init(key: .text("payload"), value: payload),
        ])
        // Duplicate keys are structurally impossible here.
        return try! CanonicalCBOREncoder().encode(env)
    }

    static func textKeyedMap(_ entries: [CanonicalCBORValue.MapEntry]) throws -> [String: CanonicalCBORValue] {
        var out: [String: CanonicalCBORValue] = [:]
        out.reserveCapacity(entries.count)
        for e in entries {
            guard case .text(let k) = e.key else { throw GossipV1FrameError.invalidScalar(field: "map_key") }
            out[k] = e.value
        }
        return out
    }

    /// For top-level envelope parsing, ignore non-text keys (forward compatibility).
    static func envelopeTextKeyedMapIgnoringNonTextKeys(_ entries: [CanonicalCBORValue.MapEntry]) -> [String: CanonicalCBORValue] {
        var out: [String: CanonicalCBORValue] = [:]
        out.reserveCapacity(entries.count)
        for e in entries {
            guard case .text(let k) = e.key else { continue }
            out[k] = e.value
        }
        return out
    }

    static func requireExactPayloadKeys(_ payload: [String: CanonicalCBORValue], required: [String]) throws {
        let requiredSet = Set(required)
        let actualSet = Set(payload.keys)
        guard requiredSet == actualSet else {
            throw GossipV1FrameError.payloadKeysMismatch(
                expected: required.sorted(),
                actual: payload.keys.sorted()
            )
        }
    }

    static func requireText(_ value: CanonicalCBORValue, field: String) throws -> String {
        guard case .text(let s) = value else { throw GossipV1FrameError.invalidScalar(field: field) }
        return s
    }

    static func requireUnsigned(_ value: CanonicalCBORValue, field: String) throws -> UInt64 {
        guard case .unsigned(let v) = value else { throw GossipV1FrameError.invalidScalar(field: field) }
        return v
    }

    static func requireBytes(_ value: CanonicalCBORValue, field: String) throws -> Data {
        guard case .bytes(let b) = value else { throw GossipV1FrameError.invalidScalar(field: field) }
        return b
    }

    static func requireArray(_ value: CanonicalCBORValue, field: String) throws -> [CanonicalCBORValue] {
        guard case .array(let a) = value else { throw GossipV1FrameError.invalidScalar(field: field) }
        return a
    }

    static func requireMap(_ value: CanonicalCBORValue, field: String) throws -> [String: CanonicalCBORValue] {
        guard case .map(let entries) = value else { throw GossipV1FrameError.invalidScalar(field: field) }
        return try textKeyedMap(entries)
    }
}

// MARK: - Payload encode/decode

private extension GossipV1HelloFrame {
    static let requiredKeys = [
        "version",
        "node_id",
        "node_pubkey",
        "capabilities",
        "propagation_class",
        "max_want",
        "max_transfer",
    ]

    func payloadCBOR() -> CanonicalCBORValue {
        .map([
            .init(key: .text("version"), value: .unsigned(version)),
            .init(key: .text("node_id"), value: .text(nodeID.hex)),
            .init(key: .text("node_pubkey"), value: .text(nodePublicKeyBase64URL)),
            .init(key: .text("capabilities"), value: .array(capabilities.map { .text($0) })),
            .init(key: .text("propagation_class"), value: .text(propagationClass)),
            .init(key: .text("max_want"), value: .unsigned(maxWant)),
            .init(key: .text("max_transfer"), value: .unsigned(maxTransfer)),
        ])
    }

    static func decodePayload(_ payload: CanonicalCBORValue) throws -> GossipV1HelloFrame {
        let dict = try GossipV1CBOR.requireMap(payload, field: "payload")
        try GossipV1CBOR.requireExactPayloadKeys(dict, required: requiredKeys)

        let version = try GossipV1CBOR.requireUnsigned(dict["version"]!, field: "version")
        let nodeIDHex = try GossipV1CBOR.requireText(dict["node_id"]!, field: "node_id")
        let pubKeyB64 = try GossipV1CBOR.requireText(dict["node_pubkey"]!, field: "node_pubkey")
        let capabilitiesValue = try GossipV1CBOR.requireArray(dict["capabilities"]!, field: "capabilities")
        let propagationClass = try GossipV1CBOR.requireText(dict["propagation_class"]!, field: "propagation_class")
        let maxWant = try GossipV1CBOR.requireUnsigned(dict["max_want"]!, field: "max_want")
        let maxTransfer = try GossipV1CBOR.requireUnsigned(dict["max_transfer"]!, field: "max_transfer")

        let nodeID = try GossipV1NodeID(hex: nodeIDHex)
        let pubKeyRaw = try GossipV1Base64URL.decode(pubKeyB64)
        let capabilities: [String] = try capabilitiesValue.map { try GossipV1CBOR.requireText($0, field: "capabilities") }

        return try GossipV1HelloFrame(
            version: version,
            nodeID: nodeID,
            nodePublicKeyRawBytes: pubKeyRaw,
            capabilities: capabilities,
            propagationClass: propagationClass,
            maxWant: maxWant,
            maxTransfer: maxTransfer
        )
    }
}

private extension GossipV1SummaryFrame {
    static let requiredKeys = ["bloom_filter", "item_count"]

    func payloadCBOR() -> CanonicalCBORValue {
        .map([
            .init(key: .text("bloom_filter"), value: .bytes(bloomFilter)),
            .init(key: .text("item_count"), value: .unsigned(itemCount)),
        ])
    }

    static func decodePayload(_ payload: CanonicalCBORValue) throws -> GossipV1SummaryFrame {
        let dict = try GossipV1CBOR.requireMap(payload, field: "payload")
        try GossipV1CBOR.requireExactPayloadKeys(dict, required: requiredKeys)

        let bloom = try GossipV1CBOR.requireBytes(dict["bloom_filter"]!, field: "bloom_filter")
        let itemCount = try GossipV1CBOR.requireUnsigned(dict["item_count"]!, field: "item_count")
        return try GossipV1SummaryFrame(bloomFilter: bloom, itemCount: itemCount)
    }
}

private extension GossipV1RequestFrame {
    static let requiredKeys = ["want"]

    func payloadCBOR() -> CanonicalCBORValue {
        .map([
            .init(key: .text("want"), value: .array(want.map { .text($0.hex) })),
        ])
    }

    static func decodePayload(_ payload: CanonicalCBORValue) throws -> GossipV1RequestFrame {
        let dict = try GossipV1CBOR.requireMap(payload, field: "payload")
        try GossipV1CBOR.requireExactPayloadKeys(dict, required: requiredKeys)

        let wantValues = try GossipV1CBOR.requireArray(dict["want"]!, field: "want")
        if wantValues.count > GossipV1.MAX_WANT_ITEMS {
            throw GossipV1FrameError.wantTooManyItems(max: GossipV1.MAX_WANT_ITEMS, actual: wantValues.count)
        }

        var want: [GossipV1ItemID] = []
        want.reserveCapacity(wantValues.count)
        var seen = Set<GossipV1ItemID>()
        seen.reserveCapacity(wantValues.count)
        for v in wantValues {
            let hex = try GossipV1CBOR.requireText(v, field: "want")
            let id = try GossipV1ItemID(hex: hex)
            guard seen.insert(id).inserted else { throw GossipV1FrameError.duplicateItemID }
            want.append(id)
        }
        return try GossipV1RequestFrame(want: want)
    }
}

private extension GossipV1TransferFrame {
    static let requiredKeys = ["objects"]

    func payloadCBOR() -> CanonicalCBORValue {
        .map([
            .init(key: .text("objects"), value: .array(objects.map { $0.cborValue() })),
        ])
    }

    static func decodePayload(_ payload: CanonicalCBORValue) throws -> GossipV1TransferFrame {
        let dict = try GossipV1CBOR.requireMap(payload, field: "payload")
        try GossipV1CBOR.requireExactPayloadKeys(dict, required: requiredKeys)

        let objectsValue = try GossipV1CBOR.requireArray(dict["objects"]!, field: "objects")
        if objectsValue.count > GossipV1.MAX_TRANSFER_ITEMS {
            throw GossipV1FrameError.transferTooManyObjects(max: GossipV1.MAX_TRANSFER_ITEMS, actual: objectsValue.count)
        }

        var objects: [Object] = []
        objects.reserveCapacity(objectsValue.count)

        var totalEnvelopeBytes = 0
        var seenIDs = Set<GossipV1ItemID>()
        seenIDs.reserveCapacity(objectsValue.count)

        for v in objectsValue {
            let obj = try Object.decode(from: v)
            guard seenIDs.insert(obj.itemID).inserted else { throw GossipV1FrameError.duplicateItemID }
            totalEnvelopeBytes += obj.envelopeBytes.count
            if totalEnvelopeBytes > GossipV1.MAX_TRANSFER_BYTES {
                throw GossipV1FrameError.transferTotalEnvelopeBytesTooLarge(max: GossipV1.MAX_TRANSFER_BYTES, actual: totalEnvelopeBytes)
            }
            try rejectIfExpired(expiryUnixMs: obj.expiryUnixMs)
            objects.append(obj)
        }

        return try GossipV1TransferFrame(objects: objects)
    }

    static func isCanonicalCBORBytes(_ bytes: Data) -> Bool {
        do {
            let v = try CanonicalCBORDecoder().decode(bytes)
            let re = try CanonicalCBOREncoder().encode(v)
            return re == bytes
        } catch {
            return false
        }
    }

    static func rejectIfExpired(expiryUnixMs: UInt64, nowUnixMs: UInt64 = nowUnixMs()) throws {
        let cutoff = nowUnixMs &+ GossipV1.CLOCK_SKEW_TOLERANCE_MS
        if cutoff >= expiryUnixMs {
            throw GossipV1FrameError.transferExpiredObject
        }
    }

    static func nowUnixMs() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000)
    }
}

private extension GossipV1TransferFrame.Object {
    static let requiredKeys = ["item_id", "envelope_b64", "expiry_unix_ms", "hop_count"]

    func cborValue() -> CanonicalCBORValue {
        .map([
            .init(key: .text("item_id"), value: .text(itemID.hex)),
            .init(key: .text("envelope_b64"), value: .text(envelopeBase64URL)),
            .init(key: .text("expiry_unix_ms"), value: .unsigned(expiryUnixMs)),
            .init(key: .text("hop_count"), value: .unsigned(UInt64(hopCount))),
        ])
    }

    static func decode(from value: CanonicalCBORValue) throws -> GossipV1TransferFrame.Object {
        let dict = try GossipV1CBOR.requireMap(value, field: "object")
        try GossipV1CBOR.requireExactPayloadKeys(dict, required: requiredKeys)

        let itemHex = try GossipV1CBOR.requireText(dict["item_id"]!, field: "item_id")
        let envelopeB64 = try GossipV1CBOR.requireText(dict["envelope_b64"]!, field: "envelope_b64")
        let expiry = try GossipV1CBOR.requireUnsigned(dict["expiry_unix_ms"]!, field: "expiry_unix_ms")
        let hopUnsigned = try GossipV1CBOR.requireUnsigned(dict["hop_count"]!, field: "hop_count")
        guard hopUnsigned <= UInt64(UInt16.max) else {
            throw GossipV1FrameError.invalidRange(field: "hop_count")
        }

        let itemID = try GossipV1ItemID(hex: itemHex)
        let envelopeBytes = try GossipV1Base64URL.decode(envelopeB64)
        guard GossipV1TransferFrame.isCanonicalCBORBytes(envelopeBytes) else {
            throw GossipV1FrameError.transferEnvelopeNotCanonical
        }
        let derived = GossipV1ItemID.derive(fromEnvelopeBytes: envelopeBytes)
        guard derived == itemID else {
            throw GossipV1FrameError.transferItemIDMismatch
        }

        return try GossipV1TransferFrame.Object(
            itemID: itemID,
            envelopeBytes: envelopeBytes,
            expiryUnixMs: expiry,
            hopCount: UInt16(hopUnsigned)
        )
    }
}

private extension GossipV1ReceiptFrame {
    static let requiredKeys = ["received"]

    func payloadCBOR() -> CanonicalCBORValue {
        .map([
            .init(key: .text("received"), value: .array(received.map { .text($0.hex) })),
        ])
    }

    static func decodePayload(_ payload: CanonicalCBORValue) throws -> GossipV1ReceiptFrame {
        let dict = try GossipV1CBOR.requireMap(payload, field: "payload")
        try GossipV1CBOR.requireExactPayloadKeys(dict, required: requiredKeys)

        let values = try GossipV1CBOR.requireArray(dict["received"]!, field: "received")
        var received: [GossipV1ItemID] = []
        received.reserveCapacity(values.count)
        var seen = Set<GossipV1ItemID>()
        seen.reserveCapacity(values.count)
        for v in values {
            let hex = try GossipV1CBOR.requireText(v, field: "received")
            let id = try GossipV1ItemID(hex: hex)
            guard seen.insert(id).inserted else { throw GossipV1FrameError.duplicateItemID }
            received.append(id)
        }
        return try GossipV1ReceiptFrame(received: received)
    }
}

private extension GossipV1RelayIngestFrame {
    static let requiredKeys = ["item_ids"]

    func payloadCBOR() -> CanonicalCBORValue {
        .map([
            .init(key: .text("item_ids"), value: .array(itemIDs.map { .text($0.hex) })),
        ])
    }

    static func decodePayload(_ payload: CanonicalCBORValue) throws -> GossipV1RelayIngestFrame {
        let dict = try GossipV1CBOR.requireMap(payload, field: "payload")
        try GossipV1CBOR.requireExactPayloadKeys(dict, required: requiredKeys)

        let values = try GossipV1CBOR.requireArray(dict["item_ids"]!, field: "item_ids")
        var itemIDs: [GossipV1ItemID] = []
        itemIDs.reserveCapacity(values.count)
        var seen = Set<GossipV1ItemID>()
        seen.reserveCapacity(values.count)
        for v in values {
            let hex = try GossipV1CBOR.requireText(v, field: "item_ids")
            let id = try GossipV1ItemID(hex: hex)
            guard seen.insert(id).inserted else { throw GossipV1FrameError.duplicateItemID }
            itemIDs.append(id)
        }
        return try GossipV1RelayIngestFrame(itemIDs: itemIDs)
    }
}
