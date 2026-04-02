public enum TelemetryLayer: String, Equatable, Sendable, Codable {
    case encounter
    case forwarding
    case adminRecord = "admin_record"
}

public enum JSONValue: Equatable, Sendable, Codable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
            return
        }
        if let boolValue = try? container.decode(Bool.self) {
            self = .bool(boolValue)
            return
        }
        if let intValue = try? container.decode(Int64.self) {
            self = .int(intValue)
            return
        }
        if let doubleValue = try? container.decode(Double.self) {
            self = .double(doubleValue)
            return
        }
        if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
            return
        }
        if let arrayValue = try? container.decode([JSONValue].self) {
            self = .array(arrayValue)
            return
        }
        if let objectValue = try? container.decode([String: JSONValue].self) {
            self = .object(objectValue)
            return
        }

        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSONValue payload")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

public struct EmptyTelemetryPayload: Equatable, Sendable {
    public init() {}

    public func asObject() -> [String: JSONValue] {
        [:]
    }
}

public struct TelemetryEvent: Equatable, Sendable, Codable {
    public let contractVersion: UInt8
    public let eventID: EventID
    public let layer: TelemetryLayer
    public let eventType: String
    public let eventSequence: UInt64
    public let occurredAtUnixMs: UInt64
    public let encounterContextID: EncounterContextID
    public let encounterInstanceID: EncounterInstanceID
    public let encounterAttemptID: EncounterAttemptID
    public let bearerID: BearerID?
    public let payload: [String: JSONValue]

    public init(
        contractVersion: UInt8 = 1,
        eventID: EventID,
        layer: TelemetryLayer,
        eventType: String,
        eventSequence: UInt64,
        occurredAtUnixMs: UInt64,
        encounterContextID: EncounterContextID,
        encounterInstanceID: EncounterInstanceID,
        encounterAttemptID: EncounterAttemptID,
        bearerID: BearerID? = nil,
        payload: [String: JSONValue] = [:]
    ) {
        self.contractVersion = contractVersion
        self.eventID = eventID
        self.layer = layer
        self.eventType = eventType
        self.eventSequence = eventSequence
        self.occurredAtUnixMs = occurredAtUnixMs
        self.encounterContextID = encounterContextID
        self.encounterInstanceID = encounterInstanceID
        self.encounterAttemptID = encounterAttemptID
        self.bearerID = bearerID
        self.payload = payload
    }
}

public protocol TelemetrySink: Sendable {
    func record(_ event: TelemetryEvent)
}
