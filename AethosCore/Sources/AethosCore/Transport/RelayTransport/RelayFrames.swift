import Foundation

// MARK: - Client-Relay Protocol Frames

/// Frame types for client-relay and relay-relay communication.
/// Supports both client transport and federation-ready relay peering.
///
/// Wire format: [typeId: UInt8][length: UInt32 big-endian][payload: bytes]
///
/// Client frames: clientHello, publish, deliver, ack, heartbeat, heartbeatAck
/// Federation scaffold frames: relayPeerHello, relayInventory, relayForward
public enum RelayFrame: Equatable, Sendable {

    // -- Client frames --

    /// Client announces itself to a relay with its wayfarer ID.
    case clientHello(wayfarerId: String)

    /// Client publishes an outbound envelope to the relay.
    /// Contains the envelope ID (for dedup/ack) and the opaque payload.
    case publish(envelopeId: Data, payload: Data)

    /// Relay delivers an inbound envelope to the client.
    /// Contains the envelope ID, opaque payload, and optional metadata.
    case deliver(envelopeId: Data, payload: Data, metadata: Data)

    /// Acknowledgment of a publish or deliver (keyed by envelope ID).
    case ack(envelopeId: Data)

    /// Negative acknowledgment with reason.
    case nack(envelopeId: Data, reason: String)

    /// Heartbeat to keep connection alive.
    case heartbeat

    /// Response to heartbeat.
    case heartbeatAck

    // -- Federation scaffold frames (relay-to-relay only) --

    /// Relay announces itself to a peer relay for federation.
    /// Contains the relay's own identifier.
    case relayPeerHello(relayId: String)

    /// Relay exchanges inventory summary with a peer relay.
    /// Contains an opaque inventory blob (format TBD in Bead 4).
    case relayInventory(Data)

    /// Relay forwards an envelope to a peer relay on behalf of a client.
    /// Contains envelope ID and the opaque payload.
    case relayForward(envelopeId: Data, payload: Data)

    // MARK: - Legacy Compatibility

    /// Legacy envelope frame (maps to publish for encoding, deliver for decoding).
    /// Retained for backward compatibility with existing tests.
    case envelope(Data)

    // MARK: - Frame Type IDs

    public static let clientHelloTypeId: UInt8 = 0x10
    public static let publishTypeId: UInt8 = 0x11
    public static let deliverTypeId: UInt8 = 0x12
    public static let ackTypeId: UInt8 = 0x02
    public static let nackTypeId: UInt8 = 0x03
    public static let heartbeatTypeId: UInt8 = 0x04
    public static let heartbeatAckTypeId: UInt8 = 0x05
    public static let relayPeerHelloTypeId: UInt8 = 0x20
    public static let relayInventoryTypeId: UInt8 = 0x21
    public static let relayForwardTypeId: UInt8 = 0x22
    public static let envelopeTypeId: UInt8 = 0x01

    // MARK: - Encoding

    /// Encode the frame for wire transport.
    /// Format: [typeId: 1 byte][payloadLength: 4 bytes big-endian][payload: N bytes]
    public func encode() throws -> Data {
        let typeId: UInt8
        var payload = Data()

        switch self {
        case .clientHello(let wayfarerId):
            typeId = Self.clientHelloTypeId
            payload = Data(wayfarerId.utf8)

        case .publish(let envelopeId, let body):
            typeId = Self.publishTypeId
            payload = encodeIdAndPayload(id: envelopeId, body: body)

        case .deliver(let envelopeId, let body, let metadata):
            typeId = Self.deliverTypeId
            payload = encodeIdPayloadAndMetadata(
                id: envelopeId, body: body, metadata: metadata
            )

        case .ack(let envelopeId):
            typeId = Self.ackTypeId
            payload = envelopeId

        case .nack(let envelopeId, let reason):
            typeId = Self.nackTypeId
            let reasonBytes = Data(reason.utf8)
            payload = envelopeId + Data([0x00]) + reasonBytes

        case .heartbeat:
            typeId = Self.heartbeatTypeId

        case .heartbeatAck:
            typeId = Self.heartbeatAckTypeId

        case .relayPeerHello(let relayId):
            typeId = Self.relayPeerHelloTypeId
            payload = Data(relayId.utf8)

        case .relayInventory(let blob):
            typeId = Self.relayInventoryTypeId
            payload = blob

        case .relayForward(let envelopeId, let body):
            typeId = Self.relayForwardTypeId
            payload = encodeIdAndPayload(id: envelopeId, body: body)

        case .envelope(let data):
            typeId = Self.envelopeTypeId
            payload = data
        }

        var frame = Data()
        frame.append(typeId)
        var length = UInt32(payload.count).bigEndian
        frame.append(contentsOf: withUnsafeBytes(of: &length) { Data($0) })
        frame.append(payload)
        return frame
    }

    /// Decode a frame from wire data.
    /// Returns nil if the data is too short or the type ID is unrecognized.
    public static func decode(_ data: Data) throws -> RelayFrame? {
        guard data.count >= 5 else { return nil }

        let typeId = data[0]
        let length = data.subdata(in: 1..<5).withUnsafeBytes {
            UInt32(bigEndian: $0.load(as: UInt32.self))
        }

        guard data.count >= 5 + Int(length) else { return nil }

        let payload = data.subdata(in: 5..<(5 + Int(length)))

        switch typeId {
        case clientHelloTypeId:
            guard let wayfarerId = String(data: payload, encoding: .utf8) else {
                return nil
            }
            return .clientHello(wayfarerId: wayfarerId)

        case publishTypeId:
            guard let (envelopeId, body) = decodeIdAndPayload(payload) else {
                return nil
            }
            return .publish(envelopeId: envelopeId, payload: body)

        case deliverTypeId:
            guard let (envelopeId, body, metadata) = decodeIdPayloadAndMetadata(payload) else {
                return nil
            }
            return .deliver(envelopeId: envelopeId, payload: body, metadata: metadata)

        case ackTypeId:
            return .ack(envelopeId: payload)

        case nackTypeId:
            guard let zeroIndex = payload.firstIndex(of: 0x00) else {
                return .nack(envelopeId: payload, reason: "unknown")
            }
            let envelopeId = Data(payload[..<zeroIndex])
            let reasonData = payload[(zeroIndex + 1)...]
            let reason = String(data: reasonData, encoding: .utf8) ?? "unknown"
            return .nack(envelopeId: envelopeId, reason: reason)

        case heartbeatTypeId:
            return .heartbeat

        case heartbeatAckTypeId:
            return .heartbeatAck

        case relayPeerHelloTypeId:
            guard let relayId = String(data: payload, encoding: .utf8) else {
                return nil
            }
            return .relayPeerHello(relayId: relayId)

        case relayInventoryTypeId:
            return .relayInventory(payload)

        case relayForwardTypeId:
            guard let (envelopeId, body) = decodeIdAndPayload(payload) else {
                return nil
            }
            return .relayForward(envelopeId: envelopeId, payload: body)

        case envelopeTypeId:
            return .envelope(payload)

        default:
            return nil
        }
    }

    // MARK: - Payload Helpers

    /// Encode an ID (4-byte length prefix) followed by a body.
    private func encodeIdAndPayload(id: Data, body: Data) -> Data {
        var result = Data()
        var idLen = UInt32(id.count).bigEndian
        result.append(contentsOf: withUnsafeBytes(of: &idLen) { Data($0) })
        result.append(id)
        result.append(body)
        return result
    }

    /// Decode an ID (4-byte length prefix) followed by a body.
    private static func decodeIdAndPayload(_ data: Data) -> (Data, Data)? {
        guard data.count >= 4 else { return nil }
        let idLen = Int(data.subdata(in: 0..<4).withUnsafeBytes {
            UInt32(bigEndian: $0.load(as: UInt32.self))
        })
        guard data.count >= 4 + idLen else { return nil }
        let id = data.subdata(in: 4..<(4 + idLen))
        let body = data.subdata(in: (4 + idLen)..<data.count)
        return (id, body)
    }

    /// Encode ID + body + metadata with length prefixes for each.
    private func encodeIdPayloadAndMetadata(
        id: Data, body: Data, metadata: Data
    ) -> Data {
        var result = Data()
        var idLen = UInt32(id.count).bigEndian
        result.append(contentsOf: withUnsafeBytes(of: &idLen) { Data($0) })
        result.append(id)
        var bodyLen = UInt32(body.count).bigEndian
        result.append(contentsOf: withUnsafeBytes(of: &bodyLen) { Data($0) })
        result.append(body)
        result.append(metadata)
        return result
    }

    /// Decode ID + body + metadata with length prefixes.
    private static func decodeIdPayloadAndMetadata(
        _ data: Data
    ) -> (Data, Data, Data)? {
        guard data.count >= 4 else { return nil }
        let idLen = Int(data.subdata(in: 0..<4).withUnsafeBytes {
            UInt32(bigEndian: $0.load(as: UInt32.self))
        })
        guard data.count >= 4 + idLen + 4 else { return nil }
        let id = data.subdata(in: 4..<(4 + idLen))
        let bodyOffset = 4 + idLen
        let bodyLen = Int(data.subdata(in: bodyOffset..<(bodyOffset + 4)).withUnsafeBytes {
            UInt32(bigEndian: $0.load(as: UInt32.self))
        })
        let bodyStart = bodyOffset + 4
        guard data.count >= bodyStart + bodyLen else { return nil }
        let body = data.subdata(in: bodyStart..<(bodyStart + bodyLen))
        let metadataStart = bodyStart + bodyLen
        let metadata = data.subdata(in: metadataStart..<data.count)
        return (id, body, metadata)
    }
}
