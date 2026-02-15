import Foundation

/// A known peer observed from inbound protocol frames.
public struct Peer: Equatable, Sendable {
    /// 64-char hex wayfarer ID of the peer.
    public let wayfarerId: String
    /// Epoch seconds when the peer was first observed.
    public let firstSeenAt: Int64
    /// Epoch seconds when the peer was most recently observed.
    public let lastSeenAt: Int64
    /// Epoch seconds when the last successful inventory exchange completed with this peer, if any.
    public let lastExchangeAt: Int64?
    /// Optional notes for future use.
    public let notes: String?

    public init(
        wayfarerId: String,
        firstSeenAt: Int64,
        lastSeenAt: Int64,
        lastExchangeAt: Int64? = nil,
        notes: String? = nil
    ) {
        self.wayfarerId = wayfarerId
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.lastExchangeAt = lastExchangeAt
        self.notes = notes
    }

    /// First 16 characters of the wayfarer ID for human display.
    public var shortId: String {
        String(wayfarerId.prefix(16))
    }
}
