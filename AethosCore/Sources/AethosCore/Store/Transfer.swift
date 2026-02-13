import Foundation

/// A first-class Transfer object representing a peer-to-peer file delivery.
///
/// Transfer ID uses UUIDv4: natively available in Swift Foundation, no external
/// dependencies. Temporal ordering is handled by the explicit `created_at` column,
/// so time-sortable IDs (UUIDv7/ULID) are unnecessary overhead.
public struct Transfer: Equatable, Sendable {
    public enum Direction: String, Sendable {
        case outbound
        case inbound
    }

    public enum Status: String, Sendable {
        case queued
        case sending
        case receiving
        case complete
        case failed
        case canceled
    }

    public let transferId: String
    public let direction: Direction
    public let peerFrom: String
    public let peerTo: String
    public let createdAt: Date
    public var updatedAt: Date
    public var lastActivityAt: Date
    public var status: Status

    // Payload metadata
    public var originalFilename: String?
    public var bytesTotal: Int64
    public var bytesSent: Int64
    public var bytesReceived: Int64

    // Chunking metadata
    public var partsTotal: Int32
    public var partsSent: Int32
    public var partsReceived: Int32

    // Integrity metadata
    public var manifestHash: String?
    public var payloadHash: String?
    public var verified: Bool

    // Error
    public var lastError: String?

    public init(
        transferId: String,
        direction: Direction,
        peerFrom: String,
        peerTo: String,
        createdAt: Date,
        updatedAt: Date,
        lastActivityAt: Date,
        status: Status,
        originalFilename: String? = nil,
        bytesTotal: Int64 = 0,
        bytesSent: Int64 = 0,
        bytesReceived: Int64 = 0,
        partsTotal: Int32 = 0,
        partsSent: Int32 = 0,
        partsReceived: Int32 = 0,
        manifestHash: String? = nil,
        payloadHash: String? = nil,
        verified: Bool = false,
        lastError: String? = nil
    ) {
        self.transferId = transferId
        self.direction = direction
        self.peerFrom = peerFrom
        self.peerTo = peerTo
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastActivityAt = lastActivityAt
        self.status = status
        self.originalFilename = originalFilename
        self.bytesTotal = bytesTotal
        self.bytesSent = bytesSent
        self.bytesReceived = bytesReceived
        self.partsTotal = partsTotal
        self.partsSent = partsSent
        self.partsReceived = partsReceived
        self.manifestHash = manifestHash
        self.payloadHash = payloadHash
        self.verified = verified
        self.lastError = lastError
    }

    public static func newId() -> String {
        UUID().uuidString.lowercased()
    }
}
