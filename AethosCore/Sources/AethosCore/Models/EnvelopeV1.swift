import Foundation

public struct EnvelopeV1: Codable, Equatable, Sendable {
    public let version: ProtocolVersion

    // Visible in MVP0.
    public let toWayfarerId: Data

    // ID of the associated manifest.
    public let manifestId: Data

    // Stub payload bytes (e.g. future encrypted body).
    public let body: Data

    public init(
        version: ProtocolVersion = .v1,
        toWayfarerId: Data,
        manifestId: Data,
        body: Data
    ) {
        self.version = version
        self.toWayfarerId = toWayfarerId
        self.manifestId = manifestId
        self.body = body
    }
}
