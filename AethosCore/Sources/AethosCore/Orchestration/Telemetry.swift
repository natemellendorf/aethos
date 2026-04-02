public enum TelemetryLayer: String, Equatable, Sendable, Codable {
    case encounter
    case forwarding
    case adminRecord = "admin_record"
}

/// Lightweight JSON-compatible value model for telemetry payloads.
///
/// Numeric decode normalization is deterministic: integer decoding is attempted
/// before floating-point decoding, so values like `1` decode as `.int(1)`.
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

public struct TelemetryEvent: Equatable, Sendable, Codable {
    public let contractVersion: UInt8 = 1
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

    private enum CodingKeys: String, CodingKey {
        case contractVersion
        case eventID
        case layer
        case eventType
        case eventSequence
        case occurredAtUnixMs
        case encounterContextID
        case encounterInstanceID
        case encounterAttemptID
        case bearerID
        case payload
    }

    public init(
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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedContractVersion = try container.decode(UInt8.self, forKey: .contractVersion)
        guard decodedContractVersion == 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .contractVersion,
                in: container,
                debugDescription: "Unsupported telemetry contractVersion: \(decodedContractVersion). Expected 1."
            )
        }

        eventID = try container.decode(EventID.self, forKey: .eventID)
        layer = try container.decode(TelemetryLayer.self, forKey: .layer)
        eventType = try container.decode(String.self, forKey: .eventType)
        eventSequence = try container.decode(UInt64.self, forKey: .eventSequence)
        occurredAtUnixMs = try container.decode(UInt64.self, forKey: .occurredAtUnixMs)
        encounterContextID = try container.decode(EncounterContextID.self, forKey: .encounterContextID)
        encounterInstanceID = try container.decode(EncounterInstanceID.self, forKey: .encounterInstanceID)
        encounterAttemptID = try container.decode(EncounterAttemptID.self, forKey: .encounterAttemptID)
        bearerID = try container.decodeIfPresent(BearerID.self, forKey: .bearerID)
        payload = try container.decodeIfPresent([String: JSONValue].self, forKey: .payload) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(contractVersion, forKey: .contractVersion)
        try container.encode(eventID, forKey: .eventID)
        try container.encode(layer, forKey: .layer)
        try container.encode(eventType, forKey: .eventType)
        try container.encode(eventSequence, forKey: .eventSequence)
        try container.encode(occurredAtUnixMs, forKey: .occurredAtUnixMs)
        try container.encode(encounterContextID, forKey: .encounterContextID)
        try container.encode(encounterInstanceID, forKey: .encounterInstanceID)
        try container.encode(encounterAttemptID, forKey: .encounterAttemptID)
        try container.encodeIfPresent(bearerID, forKey: .bearerID)
        try container.encode(payload, forKey: .payload)
    }
}

public protocol TelemetrySink: Sendable {
    func record(_ event: TelemetryEvent)
}
