import Foundation
import Testing
@testable import AethosCore

@Test
func wayfarerPayloadFixturesMatchExpectedOutcomes() throws {
    let manifest = try loadWayfarerFixtureManifest()

    for fixtureRef in manifest.fixtures {
        let fixture = try loadWayfarerFixture(named: fixtureRef.path)
        let body = try #require(Hex.decode(fixture.bodyCborHex))

        #expect(fixture.id == fixtureRef.id)
        #expect(fixture.payloadType == nil)

        switch fixture.expectedOutcome {
        case "accept/display":
            let classification = try WayfarerPayloadCodec.classify(body: body)
            #expect(classification.outcome == .acceptDisplay)
            #expect(classification.type == fixtureRef.payloadType)
            if case .chat(let chat) = classification {
                #expect(chat.text == stringValue(fixture.expectedDecodedMap?["text"]))
                #expect(chat.createdAtUnixMs == intValue(fixture.expectedDecodedMap?["created_at_unix_ms"]))
            } else {
                Issue.record("Expected chat payload for fixture \(fixture.id)")
            }

        case "accept/store-no-display":
            let classification = try WayfarerPayloadCodec.classify(body: body)
            #expect(classification.outcome == .acceptStoreNoDisplay)
            #expect(classification.type == fixtureRef.payloadType)

        case "unsupported-safe-skip":
            let classification = try WayfarerPayloadCodec.classify(body: body)
            #expect(classification.outcome == .unsupportedSafeSkip)
            #expect(classification.type == fixtureRef.payloadType)

        case "reject":
            #expect(throws: (any Error).self) {
                _ = try WayfarerPayloadCodec.classify(body: body)
            }

        default:
            Issue.record("Unexpected fixture outcome \(fixture.expectedOutcome)")
        }
    }
}

@Test
func wayfarerPayloadChatTextReturnsRenderableTextOnlyForChat() throws {
    let chatFixture = try loadWayfarerFixture(named: "valid_wayfarer_chat_v1.json")
    let mediaFixture = try loadWayfarerFixture(named: "valid_wayfarer_media_manifest_v1.json")

    let chatBody = try #require(Hex.decode(chatFixture.bodyCborHex))
    let mediaBody = try #require(Hex.decode(mediaFixture.bodyCborHex))

    #expect(WayfarerPayloadCodec.chatText(body: chatBody) == "hello wayfarer")
    #expect(WayfarerPayloadCodec.chatText(body: mediaBody) == nil)
}

private struct WayfarerFixtureManifest: Decodable {
    struct FixtureRef: Decodable {
        let id: String
        let path: String
        let payloadType: String?

        private enum CodingKeys: String, CodingKey {
            case id
            case path
            case payloadType = "payload_type"
        }
    }

    let fixtures: [FixtureRef]
}

private struct WayfarerFixture: Decodable {
    let id: String
    let bodyCborHex: String
    let payloadType: String?
    let expectedDecodedMap: [String: JSONValue]?
    let expectedOutcome: String

    private enum CodingKeys: String, CodingKey {
        case id
        case bodyCborHex = "body_cbor_hex"
        case payloadType = "payload_type"
        case expectedDecodedMap = "expected_decoded_map"
        case expectedOutcome = "expected_outcome"
    }
}

private enum JSONValue: Decodable {
    case string(String)
    case int(Int64)
    case object([String: JSONValue])
    case array([JSONValue])
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if container.decodeNil() {
            self = .null
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON fixture value")
        }
    }
}

private func stringValue(_ value: JSONValue?) -> String? {
    guard case .string(let text)? = value else { return nil }
    return text
}

private func intValue(_ value: JSONValue?) -> Int64? {
    guard case .int(let number)? = value else { return nil }
    return number
}

private func loadWayfarerFixtureManifest() throws -> WayfarerFixtureManifest {
    let data = try Data(contentsOf: fixturesRoot().appendingPathComponent("manifest.json"))
    return try JSONDecoder().decode(WayfarerFixtureManifest.self, from: data)
}

private func loadWayfarerFixture(named name: String) throws -> WayfarerFixture {
    let data = try Data(contentsOf: fixturesRoot().appendingPathComponent(name))
    return try JSONDecoder().decode(WayfarerFixture.self, from: data)
}

private func fixturesRoot(filePath: String = #filePath) -> URL {
    URL(fileURLWithPath: filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/App/wayfarer-payload-taxonomy", isDirectory: true)
}
