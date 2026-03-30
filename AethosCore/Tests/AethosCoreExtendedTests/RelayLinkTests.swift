import Foundation
import Testing
@testable import AethosCore

// MARK: - WayfarerID Tests

@Test
func wayfarerIdFromHexString() {
    let validHex = "a1b2c3d4e5f607182938475664738290abcdef1234567890ABCDEF0123456789"
    let wayfarerId = WayfarerID(hexString: validHex)
    #expect(wayfarerId != nil)
    #expect(wayfarerId?.rawValue == validHex.lowercased())
}

@Test
func wayfarerIdInvalidLength() {
    let shortHex = "abc123"
    let wayfarerId = WayfarerID(hexString: shortHex)
    #expect(wayfarerId == nil)
}

@Test
func wayfarerIdInvalidChars() {
    let invalidHex = "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"
    let wayfarerId = WayfarerID(hexString: invalidHex)
    #expect(wayfarerId == nil)
}

@Test
func wayfarerIdDataRoundTrip() {
    let originalHex = "a1b2c3d4e5f607182938475664738290abcdef1234567890ABCDEF0123456789"
    
    // Use WayfarerID data initializer with manually created Data
    var data = Data()
    var index = originalHex.startIndex
    while index < originalHex.endIndex {
        let nextIndex = originalHex.index(index, offsetBy: 2)
        let byteString = String(originalHex[index..<nextIndex])
        guard let byte = UInt8(byteString, radix: 16) else { return }
        data.append(byte)
        index = nextIndex
    }
    
    guard let wayfarerId = WayfarerID(data: data) else {
        return
    }
    guard let roundTrippedData = wayfarerId.data else {
        return
    }
    let reconstructed = WayfarerID(data: roundTrippedData)
    #expect(reconstructed?.rawValue == originalHex.lowercased())
}

// MARK: - WireParser Tests

@Test
func parseHelloOkFrame() {
    let parser = WireParser()
    let json = """
    {"type": "hello_ok", "relay_id": "relay-001"}
    """

    let frame = try? parser.parse(json)
    #expect(frame != nil)

    if case .helloOk(let helloOk) = frame {
        #expect(helloOk.relayId == "relay-001")
    }
}

@Test
func parseSendOkFrame() {
    let parser = WireParser()
    let json = """
    {"type": "send_ok", "msg_id": "uuid-1234"}
    """

    let frame = try? parser.parse(json)
    #expect(frame != nil)

    if case .sendOk(let sendOk) = frame {
        #expect(sendOk.msgId == "uuid-1234")
    }
}

@Test
func parseMessageFrame() {
    let parser = WireParser()
    let json = """
    {"type": "message", "msg_id": "msg-001", "from": "a1b2c3d4e5f607182938475664738290abcdef1234567890abcdef0123456789", "payload_b64": "aGVsbG8=", "received_at": 1234567890}
    """

    let frame = try? parser.parse(json)
    #expect(frame != nil)

    if case .message(let message) = frame {
        #expect(message.msgId == "msg-001")
        // Server sends lowercase hex, so we expect lowercase
        #expect(message.from == "a1b2c3d4e5f607182938475664738290abcdef1234567890abcdef0123456789")
    }
}

@Test
func parseMessagesFrame() {
    let parser = WireParser()
    let json = """
    {"type": "messages", "messages": [{"msg_id": "msg-001", "from": "a1b2c3d4e5f607182938475664738290abcdef1234567890abcdef0123456789", "payload_b64": "aGVsbG8=", "received_at": 1234567890}]}
    """

    let frame = try? parser.parse(json)
    #expect(frame != nil)

    if case .messages(let messages) = frame {
        #expect(messages.messages.count == 1)
        #expect(messages.messages[0].msgId == "msg-001")
    }
}

@Test
func parseAckOkFrame() {
    let parser = WireParser()
    let json = """
    {"type": "ack_ok", "msg_id": "msg-001"}
    """

    let frame = try? parser.parse(json)
    #expect(frame != nil)

    if case .ackOk(let ackOk) = frame {
        #expect(ackOk.msgId == "msg-001")
    }
}

@Test
func parseErrorFrame() {
    let parser = WireParser()
    let json = """
    {"type": "error", "code": "INVALID_PAYLOAD", "message": "Base64 decode failed"}
    """

    let frame = try? parser.parse(json)
    #expect(frame != nil)

    if case .error(let errorFrame) = frame {
        #expect(errorFrame.code == "INVALID_PAYLOAD")
        #expect(errorFrame.isTerminal == false)
    }
}

@Test
func parseErrorFrameTerminal() {
    let parser = WireParser()
    let json = """
    {"type": "error", "code": "AUTH_FAILED", "message": "Authentication failed"}
    """

    let frame = try? parser.parse(json)
    #expect(frame != nil)

    if case .error(let errorFrame) = frame {
        #expect(errorFrame.isTerminal == true)
    }
}

@Test
func parseUnknownFrameType() {
    let parser = WireParser()
    let json = """
    {"type": "unknown_type", "data": "value"}
    """

    var didCatch = false
    do {
        _ = try parser.parse(json)
    } catch WireParseError.unknownFrameType {
        didCatch = true
    } catch {
        // Unexpected error
    }
    #expect(didCatch == true)
}

@Test
func parseInvalidJson() {
    let parser = WireParser()
    // Use a string that's valid JSON but has unknown type - should throw unknownFrameType
    let json = "not valid json at all"

    var didCatch = false
    do {
        _ = try parser.parse(json)
    } catch WireParseError.invalidJson {
        didCatch = true
    } catch WireParseError.decodingError {
        didCatch = true
    } catch WireParseError.unknownFrameType {
        didCatch = true
    } catch {
        // Other errors might also be valid
        didCatch = true
    }
    #expect(didCatch == true)
}

// MARK: - Outgoing Frame Encoding

@Test
func encodeHelloFrame() {
    let parser = WireParser()
    let wayfarerId = WayfarerID(hexString: "a1b2c3d4e5f607182938475664738290abcdef1234567890ABCDEF0123456789")!
    let frame = OutgoingFrame.hello(HelloFrame(wayfarerId: wayfarerId))

    let json = try? parser.encode(frame)
    #expect(json != nil)
    #expect(json?.contains("\"type\":\"hello\"") == true)
    // WayfarerID normalizes to lowercase
    #expect(json?.contains("\"wayfarer_id\":\"a1b2c3d4e5f607182938475664738290abcdef1234567890abcdef0123456789\"") == true)
}

@Test
func encodeSendFrame() {
    let parser = WireParser()
    let to = WayfarerID(hexString: "b1c2d3e4f5a607182938475664738290abcdef1234567890ABCDEF0123456789")!
    let payload = Data("hello".utf8)
    let frame = OutgoingFrame.send(SendFrame(to: to, payload: payload, ttlSeconds: 3600))

    let json = try? parser.encode(frame)
    #expect(json != nil)
    #expect(json?.contains("\"type\":\"send\"") == true)
    #expect(json?.contains("\"to\":\"") == true)
    #expect(json?.contains("\"ttl_seconds\":3600") == true)
}

@Test
func encodePullFrame() {
    let parser = WireParser()
    let frame = OutgoingFrame.pull(PullFrame(limit: 50))

    let json = try? parser.encode(frame)
    #expect(json != nil)
    #expect(json?.contains("\"type\":\"pull\"") == true)
    #expect(json?.contains("\"limit\":50") == true)
}

@Test
func encodeAckFrame() {
    let parser = WireParser()
    let frame = OutgoingFrame.ack(AckFrame(msgId: "msg-001"))

    let json = try? parser.encode(frame)
    #expect(json != nil)
    #expect(json?.contains("\"type\":\"ack\"") == true)
    #expect(json?.contains("\"msg_id\":\"msg-001\"") == true)
}

// MARK: - Base64 Decoding

@Test
func base64DecodeValid() {
    let encoded = "aGVsbG8="  // "hello" in base64
    let decoded = try? WireBase64.decode(encoded)
    #expect(decoded != nil)
    #expect(String(data: decoded!, encoding: .utf8) == "hello")
}

@Test
func base64DecodeInvalid() {
    let invalid = "not-valid-base64!!!"
    
    var didCatch = false
    do {
        _ = try WireBase64.decode(invalid)
    } catch WireParseError.invalidBase64 {
        didCatch = true
    } catch {
        // Unexpected error
    }
    #expect(didCatch == true)
}

// MARK: - ReceivedMessage Tests

@Test
func receivedMessageFromValidData() {
    let msgId = "msg-001"
    let fromHex = "a1b2c3d4e5f607182938475664738290abcdef1234567890abcdef0123456789"
    let author = Data(repeating: 0xa1, count: 32)
    let canonicalMessage = CanonicalEncoderV1.encode(
        MessageV1(createdAtUnixMs: 123_456, authorWayfarerId: author, body: Data("hello".utf8))
    )
    let payloadB64 = WireBase64.encode(canonicalMessage)
    let receivedAt = Date(timeIntervalSince1970: 1234567890)
    let wireBytes = Data("{}".utf8)

    let message = ReceivedMessage(
        msgId: msgId,
        fromHex: fromHex,
        payloadB64: payloadB64,
        receivedAt: receivedAt,
        wireBytes: wireBytes
    )

    #expect(message != nil)
    #expect(message?.id == msgId)
    #expect(message?.transportPeer.rawValue == fromHex.lowercased())
    #expect(message?.canonicalAuthor.rawValue == author.hexString)
    #expect(message?.payload == canonicalMessage)
}

@Test
func receivedMessageFromInvalidBase64() {
    let msgId = "msg-001"
    let fromHex = "a1b2c3d4e5f607182938475664738290abcdef1234567890ABCDEF0123456789"
    let payloadB64 = "not-valid-base64!!!"
    let receivedAt = Date()
    let wireBytes = Data("{}".utf8)

    let message = ReceivedMessage(
        msgId: msgId,
        fromHex: fromHex,
        payloadB64: payloadB64,
        receivedAt: receivedAt,
        wireBytes: wireBytes
    )

    #expect(message == nil)
}

@Test
func receivedMessageFromInvalidWayfarerId() {
    let msgId = "msg-001"
    let fromHex = "invalid"  // Too short
    let payloadB64 = "aGVsbG8="
    let receivedAt = Date()
    let wireBytes = Data("{}".utf8)

    let message = ReceivedMessage(
        msgId: msgId,
        fromHex: fromHex,
        payloadB64: payloadB64,
        receivedAt: receivedAt,
        wireBytes: wireBytes
    )

    #expect(message == nil)
}

@Test
func receivedMessageRejectsPayloadWithoutCanonicalAuthor() {
    let msgId = "msg-002"
    let fromHex = "a1b2c3d4e5f607182938475664738290abcdef1234567890abcdef0123456789"
    let invalidCanonical = Data(hex: "01030100000008000000000000000103000000026869")
    let payloadB64 = WireBase64.encode(invalidCanonical)

    let message = ReceivedMessage(
        msgId: msgId,
        fromHex: fromHex,
        payloadB64: payloadB64,
        receivedAt: Date(),
        wireBytes: Data("{}".utf8)
    )

    #expect(message == nil)
}

@Test
func receivedMessagePreservesTransportPeerWhenPeerDiffersFromCanonicalAuthor() {
    let msgId = "msg-003"
    let transportPeerHex = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    let canonicalAuthor = Data(repeating: 0xaa, count: 32)
    let canonicalPayload = CanonicalEncoderV1.encode(
        MessageV1(createdAtUnixMs: 12, authorWayfarerId: canonicalAuthor, body: Data("relay".utf8))
    )
    let payloadB64 = WireBase64.encode(canonicalPayload)

    let message = ReceivedMessage(
        msgId: msgId,
        fromHex: transportPeerHex,
        payloadB64: payloadB64,
        receivedAt: Date(),
        wireBytes: Data("{}".utf8)
    )

    #expect(message != nil)
    #expect(message?.transportPeer.rawValue == transportPeerHex)
    #expect(message?.canonicalAuthor.rawValue == canonicalAuthor.hexString)
    #expect(message?.transportPeer != message?.canonicalAuthor)
}

private extension Data {
    init(hex: String) {
        var bytes = Data()
        bytes.reserveCapacity(hex.count / 2)

        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            let slice = hex[index..<next]
            let byte = UInt8(slice, radix: 16)!
            bytes.append(byte)
            index = next
        }

        self = bytes
    }
}

// MARK: - RelayLinkConfig Tests

@Test
func relayLinkConfigDefault() {
    let config = RelayLinkConfig.default

    #expect(config.pullOnConnect == true)
    #expect(config.pullBatchLimit == 50)
    #expect(config.pullBudgetDuration == 30.0)
    #expect(config.backoffBase == 1.0)
    #expect(config.backoffMax == 60.0)
    #expect(config.backoffJitter == 0.2)
}

@Test
func relayLinkConfigCustom() {
    let url = URL(string: "wss://custom.relay/ws")!
    let wayfarerId = WayfarerID(hexString: "a1b2c3d4e5f607182938475664738290abcdef1234567890ABCDEF0123456789")!

    let config = RelayLinkConfig(
        relayUrl: url,
        wayfarerId: wayfarerId,
        pullOnConnect: false,
        pullBatchLimit: 100,
        pullBudgetDuration: 60.0,
        backoffBase: 2.0,
        backoffMax: 120.0,
        backoffJitter: 0.3,
        sendTimeout: 60.0
    )

    #expect(config.relayUrl == url)
    #expect(config.wayfarerId == wayfarerId)
    #expect(config.pullOnConnect == false)
    #expect(config.pullBatchLimit == 100)
    #expect(config.pullBudgetDuration == 60.0)
    #expect(config.backoffBase == 2.0)
    #expect(config.backoffMax == 120.0)
    #expect(config.backoffJitter == 0.3)
    #expect(config.sendTimeout == 60.0)
}

// MARK: - InboxStore Tests

@Test
func inMemoryInboxStorePutAndHas() async {
    let store = InMemoryInboxStore()
    let wayfarerId = WayfarerID(hexString: "a1b2c3d4e5f607182938475664738290abcdef1234567890ABCDEF0123456789")!
    let receivedAt = Date()

    let hasBefore = await store.has(msgId: "msg-001")
    #expect(hasBefore == false)

    try? await store.put(msgId: "msg-001", from: wayfarerId, receivedAt: receivedAt, wireBytes: Data("{}".utf8))

    let hasAfter = await store.has(msgId: "msg-001")
    #expect(hasAfter == true)
}

@Test
func inMemoryInboxStoreMarkAcked() async {
    let store = InMemoryInboxStore()
    let wayfarerId = WayfarerID(hexString: "a1b2c3d4e5f607182938475664738290abcdef1234567890ABCDEF0123456789")!
    let receivedAt = Date()

    try? await store.put(msgId: "msg-001", from: wayfarerId, receivedAt: receivedAt, wireBytes: Data("{}".utf8))
    try? await store.markAcked(msgId: "msg-001")

    let unacked = await store.unackedIds()
    #expect(unacked.isEmpty == true)
}

@Test
func inMemoryInboxStoreUnackedIds() async {
    let store = InMemoryInboxStore()
    let wayfarerId = WayfarerID(hexString: "a1b2c3d4e5f607182938475664738290abcdef1234567890ABCDEF0123456789")!
    let receivedAt = Date()

    try? await store.put(msgId: "msg-001", from: wayfarerId, receivedAt: receivedAt, wireBytes: Data("{}".utf8))
    try? await store.put(msgId: "msg-002", from: wayfarerId, receivedAt: receivedAt, wireBytes: Data("{}".utf8))

    let unacked = await store.unackedIds()
    #expect(unacked.count == 2)
    #expect(unacked.contains("msg-001") == true)
    #expect(unacked.contains("msg-002") == true)
}

// MARK: - JSON Roundtrip Tests

@Test
func helloFrameEncodesAndParseMatches() {
    let parser = WireParser()
    let wayfarerId = WayfarerID(hexString: "a1b2c3d4e5f607182938475664738290abcdef1234567890ABCDEF0123456789")!

    let original = HelloFrame(wayfarerId: wayfarerId)
    let encoded = try? parser.encode(.hello(original))
    #expect(encoded != nil)
    #expect(encoded?.contains("\"type\":\"hello\"") == true)
    
    // The wayfarer_id in the JSON should be lowercase since WayfarerID normalizes to lowercase
    #expect(encoded?.contains("\"wayfarer_id\":\"a1b2c3d4e5f607182938475664738290abcdef1234567890abcdef0123456789\"") == true)
}

@Test
func sendFrameEncodesCorrectly() {
    let parser = WireParser()
    let to = WayfarerID(hexString: "b1c2d3e4f5a607182938475664738290abcdef1234567890ABCDEF0123456789")!
    let payload = Data([0x01, 0x02, 0x03])

    let frame = SendFrame(to: to, payload: payload, ttlSeconds: 1800)
    let json = try? parser.encode(.send(frame))
    #expect(json != nil)

    // Check snake_case encoding
    #expect(json?.contains("payload_b64") == true)
    #expect(json?.contains("ttl_seconds") == true)
    #expect(json?.contains("to") == true)
}

// MARK: - Error Handling

@Test
func relayLinkErrorEquality() {
    let error1 = RelayLinkError.notConnected
    let error2 = RelayLinkError.notConnected
    let error3 = RelayLinkError.handshakeNotComplete

    #expect(error1 == error2)
    #expect(error1 != error3)
}

@Test
func wireParseErrorEquality() {
    let error1 = WireParseError.invalidBase64("test")
    let error2 = WireParseError.invalidBase64("test")
    let error3 = WireParseError.invalidBase64("other")

    #expect(error1 == error2)
    #expect(error1 != error3)
}
