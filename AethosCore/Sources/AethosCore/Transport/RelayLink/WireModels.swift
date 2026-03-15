import Foundation

// MARK: - WayfarerID

/// A WayfarerID is the SHA256 hash of an Ed25519 public key, represented as lowercase hex (64 chars).
public struct WayfarerID: Equatable, Sendable, Hashable {
    public let rawValue: String  // 64 lowercase hex characters

    public init?(hexString: String) {
        let normalized = hexString.lowercased()
        guard normalized.count == 64 else { return nil }
        guard normalized.allSatisfy({ $0.isHexDigit }) else { return nil }
        self.rawValue = normalized
    }

    public init?(data: Data) {
        guard data.count == 32 else { return nil }
        self.rawValue = data.map { String(format: "%02x", $0) }.joined()
    }

    public var data: Data? {
        var data = Data()
        var index = rawValue.startIndex
        while index < rawValue.endIndex {
            let nextIndex = rawValue.index(index, offsetBy: 2)
            let byteString = String(rawValue[index..<nextIndex])
            guard let byte = UInt8(byteString, radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        return data
    }
}

// MARK: - JSON Wire Frame Types

/// Incoming JSON frames from the relay (relay → client).
public enum WireFrame: Sendable {
    case helloOk(HelloOkFrame)
    case sendOk(SendOkFrame)
    case message(MessageFrame)
    case messages(MessagesFrame)
    case ackOk(AckOkFrame)
    case error(ErrorFrame)
}

/// Outgoing JSON frames to the relay (client → relay).
public enum OutgoingFrame: Sendable {
    case hello(HelloFrame)
    case send(SendFrame)
    case pull(PullFrame)
    case ack(AckFrame)
}

// MARK: - Client → Relay Frames

/// Client sends immediately after WebSocket connect to identify itself.
public struct HelloFrame: Codable, Sendable {
    public let type: String = "hello"
    public let wayfarerId: String

    public init(wayfarerId: WayfarerID) {
        self.wayfarerId = wayfarerId.rawValue
    }

    public init(wayfarerId: String) {
        self.wayfarerId = wayfarerId
    }
}

/// Client sends a message to another Wayfarer via the relay.
public struct SendFrame: Codable, Sendable {
    public let type: String = "send"
    public let to: String
    public let payloadB64: String
    public let ttlSeconds: Int

    public init(to: WayfarerID, payload: Data, ttlSeconds: Int = 3600) {
        self.to = to.rawValue
        self.payloadB64 = WireBase64.encode(payload)
        self.ttlSeconds = ttlSeconds
    }

    public init(to: String, payloadB64: String, ttlSeconds: Int = 3600) {
        self.to = to
        self.payloadB64 = payloadB64
        self.ttlSeconds = ttlSeconds
    }
}

/// Client requests pending messages from the relay.
public struct PullFrame: Codable, Sendable {
    public let type: String = "pull"
    public let limit: Int

    public init(limit: Int = 50) {
        self.limit = limit
    }
}

/// Client acknowledges receipt of a message.
public struct AckFrame: Codable, Sendable {
    public let type: String = "ack"
    public let msgId: String

    public init(msgId: String) {
        self.msgId = msgId
    }
}

// MARK: - Relay → Client Frames

/// Relay acknowledges successful client authentication/registration.
public struct HelloOkFrame: Codable, Sendable {
    public let type: String
    public let relayId: String

    public init(type: String = "hello_ok", relayId: String) {
        self.type = type
        self.relayId = relayId
    }
}

/// Relay acknowledges message acceptance for delivery.
public struct SendOkFrame: Codable, Sendable {
    public let type: String
    public let msgId: String

    public init(type: String = "send_ok", msgId: String) {
        self.type = type
        self.msgId = msgId
    }
}

/// A single message delivered from the relay.
public struct MessageContent: Codable, Sendable {
    public let msgId: String
    public let from: String
    public let payloadB64: String
    public let receivedAt: Int64

    public init(
        msgId: String,
        from: String,
        payloadB64: String,
        receivedAt: Int64
    ) {
        self.msgId = msgId
        self.from = from
        self.payloadB64 = payloadB64
        self.receivedAt = receivedAt
    }
}

/// Relay delivers a message to the client (push model).
public struct MessageFrame: Codable, Sendable {
    public let type: String
    public let msgId: String
    public let from: String
    public let payloadB64: String
    public let receivedAt: Int64

    public init(
        type: String = "message",
        msgId: String,
        from: String,
        payloadB64: String,
        receivedAt: Int64
    ) {
        self.type = type
        self.msgId = msgId
        self.from = from
        self.payloadB64 = payloadB64
        self.receivedAt = receivedAt
    }

    public func toMessageContent() -> MessageContent {
        MessageContent(
            msgId: msgId,
            from: from,
            payloadB64: payloadB64,
            receivedAt: receivedAt
        )
    }
}

/// Relay responds to a pull request with multiple messages.
public struct MessagesFrame: Codable, Sendable {
    public let type: String
    public let messages: [MessageContent]

    public init(type: String = "messages", messages: [MessageContent]) {
        self.type = type
        self.messages = messages
    }
}

/// Relay acknowledges message deletion.
public struct AckOkFrame: Codable, Sendable {
    public let type: String
    public let msgId: String

    public init(type: String = "ack_ok", msgId: String) {
        self.type = type
        self.msgId = msgId
    }
}

/// Relay signals an error condition.
public struct ErrorFrame: Codable, Sendable {
    public let type: String
    public let code: String
    public let message: String

    public init(type: String = "error", code: String, message: String) {
        self.type = type
        self.code = code
        self.message = message
    }

    public var isTerminal: Bool {
        code == "AUTH_FAILED" || code == "INVALID_WAYFARER_ID"
    }
}

// MARK: - Parsed Received Message

/// A received message parsed from the wire format, ready for application use.
public struct ReceivedMessage: Sendable, Identifiable {
    public let id: String  // msgId
    public let transportPeer: WayfarerID
    public let canonicalAuthor: WayfarerID
    public let payload: Data
    public let receivedAt: Date
    public let wireBytes: Data  // Original CBOR wire bytes for storage

    public init(
        msgId: String,
        transportPeer: WayfarerID,
        canonicalAuthor: WayfarerID,
        payload: Data,
        receivedAt: Date,
        wireBytes: Data
    ) {
        self.id = msgId
        self.transportPeer = transportPeer
        self.canonicalAuthor = canonicalAuthor
        self.payload = payload
        self.receivedAt = receivedAt
        self.wireBytes = wireBytes
    }

    public init?(msgId: String, fromHex: String, payloadB64: String, receivedAt: Date, wireBytes: Data) {
        guard let transportPeer = WayfarerID(hexString: fromHex),
              let payload = try? WireBase64.decodeUrl(payloadB64),
              let message = try? CanonicalEncoderV1.decodeMessage(canonical: payload),
              let canonicalAuthor = WayfarerID(data: message.authorWayfarerId)
        else {
            return nil
        }
        self.id = msgId
        self.transportPeer = transportPeer
        self.canonicalAuthor = canonicalAuthor
        self.payload = payload
        self.receivedAt = receivedAt
        self.wireBytes = wireBytes
    }
}

// MARK: - JSON Parsing

/// Errors that can occur during frame parsing.
public enum WireParseError: Error, Equatable {
    case unknownFrameType(String)
    case invalidJson(String)
    case invalidBase64(String)
    case invalidWayfarerId(String)
    case missingField(String)
    case decodingError(String)
}

/// Strict JSON decoder for wire frames.
public struct WireParser {
    private let decoder: JSONDecoder

    public init() {
        self.decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    /// Parse an incoming wire frame from JSON string.
    public func parse(_ jsonString: String) throws -> WireFrame {
        guard let data = jsonString.data(using: .utf8) else {
            throw WireParseError.invalidJson("Not valid UTF-8")
        }

        // First, decode just the type field to determine frame type
        struct TypeOnly: Codable {
            let type: String
        }

        let typeOnly: TypeOnly
        do {
            typeOnly = try decoder.decode(TypeOnly.self, from: data)
        } catch {
            throw WireParseError.decodingError(error.localizedDescription)
        }

        switch typeOnly.type {
        case "hello_ok":
            return try .helloOk(decoder.decode(HelloOkFrame.self, from: data))
        case "send_ok":
            return try .sendOk(decoder.decode(SendOkFrame.self, from: data))
        case "message":
            return try .message(decoder.decode(MessageFrame.self, from: data))
        case "messages":
            return try .messages(decoder.decode(MessagesFrame.self, from: data))
        case "ack_ok":
            return try .ackOk(decoder.decode(AckOkFrame.self, from: data))
        case "error":
            return try .error(decoder.decode(ErrorFrame.self, from: data))
        default:
            throw WireParseError.unknownFrameType(typeOnly.type)
        }
    }

    /// Encode an outgoing frame to JSON string.
    public func encode(_ frame: OutgoingFrame) throws -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase

        let data: Data
        switch frame {
        case .hello(let hello):
            data = try encoder.encode(hello)
        case .send(let send):
            data = try encoder.encode(send)
        case .pull(let pull):
            data = try encoder.encode(pull)
        case .ack(let ack):
            data = try encoder.encode(ack)
        }

        guard let string = String(data: data, encoding: .utf8) else {
            throw WireParseError.invalidJson("Failed to encode to UTF-8")
        }
        return string
    }
}

// MARK: - Base64 Utilities

public enum WireBase64 {
    /// Decode base64url with strict mode - fails fast on invalid input.
    public static func decode(_ string: String) throws -> Data {
        try decodeUrl(string)
    }

    /// Encode to base64url string (URL-safe alphabet, no padding).
    public static func encode(_ data: Data) -> String {
        // Convert to base64 and strip padding, then make URL-safe
        data.base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }

    /// Decode base64url string (URL-safe alphabet, no padding).
    public static func decodeUrl(_ string: String) throws -> Data {
        // Convert from base64url to standard base64
        var normalized = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        
        // Add padding if needed
        let remainder = normalized.count % 4
        if remainder > 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        
        guard let data = Data(base64Encoded: normalized) else {
            throw WireParseError.invalidBase64(string)
        }
        return data
    }
}
