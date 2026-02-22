import Foundation

/// Configuration for RelayLink behavior.
public struct RelayLinkConfig: Sendable, Equatable {
    /// WebSocket URL of the relay server.
    public let relayUrl: URL

    /// Client's WayfarerID (sha256 of ed25519 pubkey).
    public let wayfarerId: WayfarerID

    /// Whether to automatically pull messages after connect/reconnect.
    public let pullOnConnect: Bool

    /// Maximum messages to request per pull.
    public let pullBatchLimit: Int

    /// Maximum duration (seconds) to spend pulling after reconnect.
    public let pullBudgetDuration: TimeInterval

    /// Base delay for exponential backoff (seconds).
    public let backoffBase: TimeInterval

    /// Maximum backoff delay (seconds).
    public let backoffMax: TimeInterval

    /// Jitter factor for backoff (0.0 to 1.0).
    public let backoffJitter: Double

    /// Timeout for send operations (seconds).
    public let sendTimeout: TimeInterval

    /// Default configuration.
    public static let `default` = RelayLinkConfig(
        relayUrl: URL(string: "wss://relay.aethos.dev/ws")!,
        wayfarerId: WayfarerID(hexString: "0000000000000000000000000000000000000000000000000000000000000000")!,
        pullOnConnect: true,
        pullBatchLimit: 50,
        pullBudgetDuration: 30.0,
        backoffBase: 1.0,
        backoffMax: 60.0,
        backoffJitter: 0.2,
        sendTimeout: 30.0
    )

    public init(
        relayUrl: URL,
        wayfarerId: WayfarerID,
        pullOnConnect: Bool = true,
        pullBatchLimit: Int = 50,
        pullBudgetDuration: TimeInterval = 30.0,
        backoffBase: TimeInterval = 1.0,
        backoffMax: TimeInterval = 60.0,
        backoffJitter: Double = 0.2,
        sendTimeout: TimeInterval = 30.0
    ) {
        self.relayUrl = relayUrl
        self.wayfarerId = wayfarerId
        self.pullOnConnect = pullOnConnect
        self.pullBatchLimit = pullBatchLimit
        self.pullBudgetDuration = pullBudgetDuration
        self.backoffBase = backoffBase
        self.backoffMax = backoffMax
        self.backoffJitter = backoffJitter
        self.sendTimeout = sendTimeout
    }
}

/// Connection state for RelayLink.
public enum RelayLinkState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting
}
