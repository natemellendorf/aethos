import Foundation

/// Protocol for storing and managing received messages (inbox).
/// Implementations handle durable persistence of messages.
public protocol RelayInboxStore: Sendable {
    /// Store a received message.
    /// - Parameters:
    ///   - msgId: Unique message identifier
    ///   - from: Sender's WayfarerID
    ///   - receivedAt: Timestamp when message was received
    ///   - wireBytes: Original CBOR wire bytes for storage
    func put(msgId: String, from: WayfarerID, receivedAt: Date, wireBytes: Data) async throws

    /// Mark a message as acknowledged (successfully processed).
    /// - Parameter msgId: The message ID to mark as acked
    func markAcked(msgId: String) async throws

    /// Check if a message has been stored.
    /// - Parameter msgId: The message ID to check
    /// - Returns: true if the message exists in the inbox
    func has(msgId: String) async -> Bool

    /// Retrieve all unacknowledged message IDs.
    /// - Returns: Array of message IDs that haven't been acked
    func unackedIds() async -> [String]
}

// MARK: - In-Memory Implementation (for testing)

/// Simple in-memory implementation of RelayInboxStore for testing.
public actor InMemoryInboxStore: RelayInboxStore {
    private var messages: [String: (from: WayfarerID, receivedAt: Date, wireBytes: Data)] = [:]
    private var acked: Set<String> = []

    public init() {}

    public func put(msgId: String, from: WayfarerID, receivedAt: Date, wireBytes: Data) async throws {
        messages[msgId] = (from, receivedAt, wireBytes)
    }

    public func markAcked(msgId: String) async throws {
        acked.insert(msgId)
    }

    public func has(msgId: String) async -> Bool {
        messages[msgId] != nil
    }

    public func unackedIds() async -> [String] {
        messages.keys.filter { !acked.contains($0) }
    }
}
