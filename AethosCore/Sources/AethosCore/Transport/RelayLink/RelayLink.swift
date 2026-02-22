import Foundation

// MARK: - Errors

/// Errors that can occur in RelayLink.
public enum RelayLinkError: Error, Equatable {
    case notConnected
    case handshakeNotComplete
    case sendTimeout
    case invalidResponse(String)
    case relayError(String, String)
    case connectionFailed(String)
    case invalidConfiguration(String)
    case pullResponseNotSupported
}

// MARK: - Pending Send

/// Tracks a pending send operation awaiting acknowledgment.
private struct PendingSend: Sendable {
    let msgId: String
    let to: WayfarerID
    let payload: Data
    let ttlSeconds: Int
    let task: CheckedContinuation<String, Error>
}

/// Type alias for pull continuation.
private typealias PullContinuation = CheckedContinuation<[ReceivedMessage], Error>

// MARK: - RelayLink

/// Actor-based WebSocket transport for JSON relay protocol.
/// Provides reliable message delivery with acknowledgment semantics.
public actor RelayLink {
    private let config: RelayLinkConfig
    private let parser: WireParser
    private var urlSession: URLSession
    private var webSocketTask: URLSessionWebSocketTask?
    private var state: RelayLinkState = .disconnected
    private var relayId: String?
    private var handshakeComplete: Bool = false
    private var helloOkContinuation: CheckedContinuation<Void, Error>?

    // Pending operations
    private var pendingSends: [String: PendingSend] = [:]
    private var pendingPull: PullContinuation?
    private var pendingAck: [String: CheckedContinuation<Void, Error>] = [:]

    // Message delivery
    private var messageContinuation: AsyncStream<ReceivedMessage>.Continuation?

    // Inbox persistence
    private let inboxStore: RelayInboxStore

    // Reconnection
    private var reconnectAttempt: Int = 0
    private var reconnectTask: Task<Void, Never>?

    // Receive loop
    private var receiveTask: Task<Void, Never>?

    public init(
        config: RelayLinkConfig,
        inboxStore: RelayInboxStore
    ) {
        self.config = config
        self.inboxStore = inboxStore
        self.parser = WireParser()

        // Configure URLSession for WebSocket
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.waitsForConnectivity = true
        self.urlSession = URLSession(configuration: sessionConfig)
    }

    /// Convenience initializer without inbox store (uses in-memory).
    public init(config: RelayLinkConfig) async {
        self.config = config
        self.inboxStore = InMemoryInboxStore()
        self.parser = WireParser()

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.waitsForConnectivity = true
        self.urlSession = URLSession(configuration: sessionConfig)
    }

    // MARK: - Public API

    /// Current connection state.
    public var connectionState: RelayLinkState {
        state
    }

    /// Relay ID after successful handshake.
    public var currentRelayId: String? {
        relayId
    }

    /// AsyncStream of received messages for push delivery.
    public var receiveStream: AsyncStream<ReceivedMessage> {
        AsyncStream { continuation in
            self.messageContinuation = continuation
            continuation.onTermination = { @Sendable _ in
                Task { @MainActor in
                    await self.clearMessageContinuation()
                }
            }
        }
    }

    private func clearMessageContinuation() {
        messageContinuation = nil
    }

    /// Connect to the relay and complete handshake.
    public func connect() async throws {
        guard state == .disconnected else { return }

        state = .connecting

        do {
            try await establishConnection()
            try await performHandshake()
            state = .connected
            reconnectAttempt = 0

            // Start receiving messages
            startReceiving()

            // Pull if configured
            if config.pullOnConnect {
                Task {
                    await pullUntilEmpty()
                }
            }
        } catch {
            state = .disconnected
            throw RelayLinkError.connectionFailed(error.localizedDescription)
        }
    }

    /// Disconnect from the relay.
    public func disconnect() async {
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil

        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil

        state = .disconnected
        handshakeComplete = false
        relayId = nil

        // Cancel pending operations
        for (_, pending) in pendingSends {
            pending.task.resume(throwing: RelayLinkError.notConnected)
        }
        pendingSends.removeAll()

        for (_, continuation) in pendingAck {
            continuation.resume(throwing: RelayLinkError.notConnected)
        }
        pendingAck.removeAll()

        helloOkContinuation?.resume(throwing: RelayLinkError.notConnected)
        helloOkContinuation = nil
    }

    /// Send a message to a recipient via the relay.
    /// - Parameters:
    ///   - to: Recipient's WayfarerID
    ///   - payload: CBOR-encoded message payload
    ///   - ttlSeconds: Time-to-live in seconds
    /// - Returns: Message ID for tracking
    public func send(to: WayfarerID, payload: Data, ttlSeconds: Int = 3600) async throws -> String {
        guard state == .connected, handshakeComplete else {
            throw RelayLinkError.handshakeNotComplete
        }

        let msgId = UUID().uuidString

        let sendFrame = SendFrame(to: to, payload: payload, ttlSeconds: ttlSeconds)
        let jsonString = try parser.encode(.send(sendFrame))

        try await sendJson(jsonString)

        // Wait for send_ok with timeout
        return try await withCheckedThrowingContinuation { continuation in
            pendingSends[msgId] = PendingSend(
                msgId: msgId,
                to: to,
                payload: payload,
                ttlSeconds: ttlSeconds,
                task: continuation
            )
            
            // Schedule timeout
            Task {
                try? await Task.sleep(nanoseconds: UInt64(config.sendTimeout * 1_000_000_000))
                // Check if still pending (not already resolved)
                if let pending = pendingSends.removeValue(forKey: msgId) {
                    pending.task.resume(throwing: RelayLinkError.sendTimeout)
                }
            }
        }
    }

    /// Pull pending messages from the relay.
    /// - Parameter limit: Maximum messages to retrieve
    /// - Returns: Array of received messages
    public func pull(limit: Int) async throws -> [ReceivedMessage] {
        guard state == .connected, handshakeComplete else {
            throw RelayLinkError.handshakeNotComplete
        }

        let pullFrame = PullFrame(limit: limit)
        let jsonString = try parser.encode(.pull(pullFrame))

        try await sendJson(jsonString)

        // Wait for messages response
        return try await withCheckedThrowingContinuation { continuation in
            self.pendingPull = continuation
        }
    }

    /// Acknowledge receipt of a message.
    /// - Parameter msgId: The message ID to acknowledge
    public func ack(msgId: String) async throws {
        guard state == .connected, handshakeComplete else {
            throw RelayLinkError.handshakeNotComplete
        }

        // Store in inbox first
        if await inboxStore.has(msgId: msgId) {
            try await inboxStore.markAcked(msgId: msgId)
        }

        let ackFrame = AckFrame(msgId: msgId)
        let jsonString = try parser.encode(.ack(ackFrame))

        try await sendJson(jsonString)

        // Wait for ack_ok
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pendingAck[msgId] = continuation
        }
    }

    // MARK: - Private Implementation

    private func establishConnection() async throws {
        let task = urlSession.webSocketTask(with: config.relayUrl)
        task.resume()
        webSocketTask = task
    }

    private func performHandshake() async throws {
        let helloFrame = HelloFrame(wayfarerId: config.wayfarerId)
        let jsonString = try parser.encode(.hello(helloFrame))

        try await sendJson(jsonString)

        // Wait for hello_ok
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.helloOkContinuation = continuation
        }
    }

    private func sendJson(_ json: String) async throws {
        guard let task = webSocketTask else {
            throw RelayLinkError.notConnected
        }

        try await task.send(.string(json))
    }

    private func startReceiving() {
        receiveTask = Task { [weak self] in
            guard let self = self else { return }
            await self.receiveLoop()
        }
    }

    private func receiveLoop() async {
        guard let task = webSocketTask else { return }

        while !Task.isCancelled {
            do {
                let message = try await task.receive()

                switch message {
                case .string(let text):
                    await handleReceivedFrame(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        await handleReceivedFrame(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                await handleDisconnect(error: error)
                break
            }
        }
    }

    private func handleReceivedFrame(_ jsonString: String) async {
        do {
            let frame = try parser.parse(jsonString)

            switch frame {
            case .helloOk(let helloOk):
                relayId = helloOk.relayId
                handshakeComplete = true
                helloOkContinuation?.resume()
                helloOkContinuation = nil

            case .sendOk(let sendOk):
                if let pending = pendingSends.removeValue(forKey: sendOk.msgId) {
                    pending.task.resume(returning: sendOk.msgId)
                }

            case .message(let messageFrame):
                await handleIncomingMessage(messageFrame, rawJson: jsonString)

            case .messages(let messagesFrame):
                // Complete any pending pull request
                if let pullContinuation = pendingPull {
                    var messages: [ReceivedMessage] = []
                    for msg in messagesFrame.messages {
                        if let message = await parseMessageContent(msg, rawJson: jsonString) {
                            messages.append(message)
                        }
                    }
                    pendingPull = nil
                    pullContinuation.resume(returning: messages)
                }

            case .ackOk(let ackOk):
                if let continuation = pendingAck.removeValue(forKey: ackOk.msgId) {
                    continuation.resume()
                }

            case .error(let errorFrame):
                // Handle error - broadcast to all pending sends
                let error = RelayLinkError.relayError(errorFrame.code, errorFrame.message)
                for (_, pending) in pendingSends {
                    pending.task.resume(throwing: error)
                }
                pendingSends.removeAll()
            }
        } catch {
            // Log parsing error but don't crash
        }
    }

    private func parseMessageContent(_ content: MessageContent, rawJson: String) async -> ReceivedMessage? {
        let receivedAt = Date(timeIntervalSince1970: TimeInterval(content.receivedAt))

        return ReceivedMessage(
            msgId: content.msgId,
            fromHex: content.from,
            payloadB64: content.payloadB64,
            receivedAt: receivedAt,
            wireBytes: Data(rawJson.utf8)
        )
    }

    private func handleIncomingMessage(_ frame: MessageFrame, rawJson: String) async {
        let receivedAt = Date(timeIntervalSince1970: TimeInterval(frame.receivedAt))

        guard let message = ReceivedMessage(
            msgId: frame.msgId,
            fromHex: frame.from,
            payloadB64: frame.payloadB64,
            receivedAt: receivedAt,
            wireBytes: Data(rawJson.utf8)
        ) else {
            return
        }

        // Store in inbox
        try? await inboxStore.put(
            msgId: frame.msgId,
            from: message.from,
            receivedAt: receivedAt,
            wireBytes: Data(rawJson.utf8)
        )

        // Push to stream
        messageContinuation?.yield(message)
    }

    private func handleDisconnect(error: Error) async {
        let previousState = state
        state = .disconnected
        handshakeComplete = false

        // Cancel pending sends
        for (_, pending) in pendingSends {
            pending.task.resume(throwing: RelayLinkError.notConnected)
        }
        pendingSends.removeAll()

        pendingPull?.resume(returning: [])
        pendingPull = nil

        // Attempt reconnect if not intentionally disconnected
        if previousState == .connected || previousState == .reconnecting {
            await attemptReconnect()
        }
    }

    private func attemptReconnect() async {
        guard state != .connected else { return }

        state = .reconnecting
        reconnectAttempt += 1

        // Calculate backoff with jitter
        let backoff = calculateBackoff(attempt: reconnectAttempt)
        try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))

        guard state != .connected else { return }

        do {
            try await connect()
        } catch {
            // Schedule another attempt
            reconnectTask = Task {
                await self.attemptReconnect()
            }
        }
    }

    private func calculateBackoff(attempt: Int) -> TimeInterval {
        let exponential = config.backoffBase * pow(2.0, Double(min(attempt, 10)))
        let capped = min(exponential, config.backoffMax)
        let jitterRange = capped * config.backoffJitter
        let jitterValue = Double.random(in: -jitterRange...jitterRange)
        return max(0, capped + jitterValue)
    }

    private func pullUntilEmpty() async {
        let startTime = Date()

        while Date().timeIntervalSince(startTime) < config.pullBudgetDuration {
            do {
                let messages = try await pull(limit: config.pullBatchLimit)

                if messages.isEmpty {
                    break
                }

                // Ack each message after processing
                for message in messages {
                    try? await ack(msgId: message.id)
                }
            } catch {
                break
            }
        }
    }
}
