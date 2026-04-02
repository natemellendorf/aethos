import Foundation

public enum TelemetryLayer: String, Equatable, Sendable, Codable {
    case encounter
    case forwarding
    case adminRecord = "admin_record"
}

public protocol TelemetryEventPayload: Sendable {
    func asDictionary() -> [String: String]
}

public struct EmptyTelemetryPayload: TelemetryEventPayload, Equatable, Sendable {
    public init() {}

    public func asDictionary() -> [String: String] {
        [:]
    }
}

public struct TelemetryEvent: Equatable, Sendable {
    public let eventID: EventID
    public let eventAtUnixMs: UInt64
    public let layer: TelemetryLayer
    public let payload: [String: String]

    public init(
        eventID: EventID,
        eventAtUnixMs: UInt64,
        layer: TelemetryLayer,
        payload: [String: String]
    ) {
        self.eventID = eventID
        self.eventAtUnixMs = eventAtUnixMs
        self.layer = layer
        self.payload = payload
    }

    public init<P: TelemetryEventPayload>(
        eventID: EventID,
        eventAtUnixMs: UInt64,
        layer: TelemetryLayer,
        payload: P
    ) {
        self.eventID = eventID
        self.eventAtUnixMs = eventAtUnixMs
        self.layer = layer
        self.payload = payload.asDictionary()
    }
}

public protocol TelemetrySink: Sendable {
    func record(_ event: TelemetryEvent)
}
