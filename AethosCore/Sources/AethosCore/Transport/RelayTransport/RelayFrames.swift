import Foundation

/// Frame types for relay-to-client communication.
/// These frame types support federation-ready relay semantics.
public enum RelayFrame: Equatable, Sendable {
    /// Envelope payload for relay forwarding.
    case envelope(Data)
    
    /// Acknowledgment of successful delivery.
    case ack(Data)
    
    /// Negative acknowledgment for delivery failure.
    case nack(Data, String)
    
    /// Heartbeat to keep connection alive.
    case heartbeat
    
    /// Response to heartbeat.
    case heartbeatAck
    
    // MARK: - Frame Type IDs
    
    public static let envelopeTypeId: UInt8 = 0x01
    public static let ackTypeId: UInt8 = 0x02
    public static let nackTypeId: UInt8 = 0x03
    public static let heartbeatTypeId: UInt8 = 0x04
    public static let heartbeatAckTypeId: UInt8 = 0x05
    
    // MARK: - Encoding
    
    /// CBOR-encode the frame for wire transport.
    public func encode() throws -> Data {
        let typeId: UInt8
        var payload = Data()
        
        switch self {
        case .envelope(let data):
            typeId = Self.envelopeTypeId
            payload = data
            
        case .ack(let envelopeId):
            typeId = Self.ackTypeId
            payload = envelopeId
            
        case .nack(let envelopeId, let reason):
            typeId = Self.nackTypeId
            var reasonData = reason.data(using: .utf8) ?? Data()
            payload = envelopeId + Data([0]) + reasonData
            
        case .heartbeat:
            typeId = Self.heartbeatTypeId
            
        case .heartbeatAck:
            typeId = Self.heartbeatAckTypeId
        }
        
        var frame = Data()
        frame.append(typeId)
        
        var length = UInt32(payload.count).bigEndian
        frame.append(contentsOf: withUnsafeBytes(of: &length) { Data($0) })
        
        frame.append(payload)
        return frame
    }
    
    /// Decode a frame from wire data.
    public static func decode(_ data: Data) throws -> RelayFrame? {
        guard data.count >= 5 else { return nil }
        
        let typeId = data[0]
        let length = UInt32(bigEndian: data.subdata(in: 1..<5).withUnsafeBytes { $0.load(as: UInt32.self) })
        
        guard data.count >= 5 + Int(length) else { return nil }
        
        let payload = data.subdata(in: 5..<(5 + Int(length)))
        
        switch typeId {
        case envelopeTypeId:
            return .envelope(payload)
            
        case ackTypeId:
            return .ack(payload)
            
        case nackTypeId:
            guard let zeroIndex = payload.firstIndex(of: 0) else {
                return .nack(payload, "unknown")
            }
            let envelopeId = payload[..<zeroIndex]
            let reasonData = payload[(zeroIndex + 1)...]
            let reason = String(data: reasonData, encoding: .utf8) ?? "unknown"
            return .nack(Data(envelopeId), reason)
            
        case heartbeatTypeId:
            return .heartbeat
            
        case heartbeatAckTypeId:
            return .heartbeatAck
            
        default:
            return nil
        }
    }
}
