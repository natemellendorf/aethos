import Foundation

public struct ReceiptV1: Codable, Equatable, Sendable {
    public let version: ProtocolVersion
    public let envelopeId: Data
    public let manifestId: Data
    public let receivedAtUnixMs: UInt64

    public init(
        version: ProtocolVersion = .v1,
        envelopeId: Data,
        manifestId: Data,
        receivedAtUnixMs: UInt64
    ) {
        self.version = version
        self.envelopeId = envelopeId
        self.manifestId = manifestId
        self.receivedAtUnixMs = receivedAtUnixMs
    }
}
