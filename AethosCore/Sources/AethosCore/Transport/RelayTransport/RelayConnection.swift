import Foundation

/// WebSocket-based relay connection implementation.
public actor WebSocketRelayConnection: RelayConnectionProtocol {
    private let config: RelayConfig
    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession
    private var isConnectedValue: Bool
    private var receiveTask: Task<Void, Never>?
    private var pendingMessages: [RelayFrame] = []
    
    public var isConnected: Bool { isConnectedValue }
    
    public init(config: RelayConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
        self.isConnectedValue = false
    }
    
    public func connect() async {
        guard !isConnectedValue else { return }
        
        var request = URLRequest(url: config.wsURL)
        request.timeoutInterval = 30.0
        
        webSocket = session.webSocketTask(with: request)
        webSocket?.resume()
        
        isConnectedValue = true
        
        receiveTask = Task {
            await receiveLoop()
        }
        
        for message in pendingMessages {
            _ = await send(message)
        }
        pendingMessages.removeAll()
    }
    
    public func disconnect() async {
        receiveTask?.cancel()
        receiveTask = nil
        
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        
        isConnectedValue = false
    }
    
    public func send(_ frame: RelayFrame) async -> Bool {
        guard isConnectedValue else {
            pendingMessages.append(frame)
            return false
        }
        
        do {
            let data = try frame.encode()
            let message = URLSessionWebSocketTask.Message.data(data)
            
            try await webSocket?.send(message)
            return true
        } catch {
            return false
        }
    }
    
    public func receive() async -> RelayFrame? {
        guard isConnectedValue else { return nil }
        
        do {
            let message = try await webSocket?.receive()
            
            switch message {
            case .data(let data):
                return try RelayFrame.decode(data)
            case .string(let text):
                if let data = text.data(using: .utf8) {
                    return try RelayFrame.decode(data)
                }
            case .none:
                return nil
            @unknown default:
                return nil
            }
        } catch {
            isConnectedValue = false
            return nil
        }
        
        return nil
    }
    
    private func receiveLoop() async {
        while isConnectedValue {
            if let _ = await receive() {
            }
            
            try? await Task.sleep(nanoseconds: 30_000_000_000)
        }
    }
}
