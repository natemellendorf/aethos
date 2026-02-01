import Foundation

public final class SimDuplexLink {
    private var aToB: [Frame] = []
    private var bToA: [Frame] = []

    public init() {}

    public func endpointA() -> Link { Endpoint(queueOut: { [weak self] frame in self?.aToB.append(frame) }, queueIn: { [weak self] in
        guard let self else { return nil }
        return self.bToA.isEmpty ? nil : self.bToA.removeFirst()
    }) }
    public func endpointB() -> Link { Endpoint(queueOut: { [weak self] frame in self?.bToA.append(frame) }, queueIn: { [weak self] in
        guard let self else { return nil }
        return self.aToB.isEmpty ? nil : self.aToB.removeFirst()
    }) }

    private struct Endpoint: Link {
        let queueOut: (Frame) -> Void
        let queueIn: () -> Frame?

        func send(_ frame: Frame) throws {
            queueOut(frame)
        }

        func receive() throws -> Frame? {
            queueIn()
        }
    }
}

public struct SimPeer {
    public let name: String
    public let store: AethosStore
    public let router: Router
    public let link: Link

    // Simulation-only state for multipart chunk delivery.
    fileprivate let sendState = ChunkSendState()
    fileprivate let receiveState = ChunkReceiveState()

    public init(name: String, store: AethosStore, link: Link) {
        self.name = name
        self.store = store
        self.router = Router(store: store)
        self.link = link
    }
}

// Mutable reference types to allow state updates without changing public API.
fileprivate final class ChunkSendState {
    var nextPartByChunkIdHex: [String: UInt16] = [:]
}

fileprivate final class ChunkReceiveState {
    struct Partial {
        let partCount: UInt16
        var parts: [UInt16: Data]
    }

    var partialByChunkIdHex: [String: Partial] = [:]

    var receivedManifestIds: Set<String> = []
    var receivedEnvelopeIds: Set<String> = []
    var receivedReceiptIds: Set<String> = []
}

public struct SessionReport: Equatable {
    public let plannedCount: Int
    public let sentFrames: Int
    public let receivedFrames: Int
    public let duplicateFrames: Int

    public init(plannedCount: Int, sentFrames: Int, receivedFrames: Int, duplicateFrames: Int) {
        self.plannedCount = plannedCount
        self.sentFrames = sentFrames
        self.receivedFrames = receivedFrames
        self.duplicateFrames = duplicateFrames
    }
}

public enum SimSession {
    public static func run(from: SimPeer, to: SimPeer, budget: SessionBudget, now: Date) throws -> SessionReport {
        // Budget is treated as a frame budget.
        let plan = try from.router.planNextSession(budget: budget, now: now)

        // Choose a payload size derived from session budget.
        // Keep it small enough to require multipart for 32KB chunks, but large enough
        // to make progress with small budgets.
        let maxFramePayloadBytes = min(
            CargoItem.defaultChunkPartBudgetBytes,
            max(1, (budget.maxBytes / 2) - 64)
        )
        var remainingBytes = budget.maxBytes
        var remainingItems = budget.maxItems

        var sentFrames = 0
        var dupFrames = 0

        for item in plan {
            if remainingItems <= 0 || remainingBytes <= 0 { break }

            switch item {
            case .receipt, .envelope, .manifest:
                let frames = try CargoCodec.encode(item, maxFramePayloadBytes: maxFramePayloadBytes)
                guard let frame = frames.first else { continue }

                // Avoid resending metadata once the receiver has it (simulation-only).
                let idHex = Hex.encode(frame.id)
                switch CargoCodec.FrameType(rawValue: frame.type) {
                case .manifest:
                    if to.receiveState.receivedManifestIds.contains(idHex) { continue }
                case .envelope:
                    if to.receiveState.receivedEnvelopeIds.contains(idHex) { continue }
                case .receipt:
                    if to.receiveState.receivedReceiptIds.contains(idHex) { continue }
                default:
                    break
                }

                if frame.sizeBytes > remainingBytes { continue }

                try from.link.send(frame)
                remainingBytes -= frame.sizeBytes
                remainingItems -= 1
                sentFrames += 1


                // Duplicate some frames intentionally.
                if sentFrames % 3 == 0, frame.sizeBytes <= remainingBytes {
                    try from.link.send(frame)
                    remainingBytes -= frame.sizeBytes
                    remainingItems -= 1
                    sentFrames += 1
                    dupFrames += 1
                }

            case let .chunk(id, bytes):
                // Multipart: send as many parts as fit in the budget for this session,
                // advancing a per-sender cursor so we eventually deliver the full chunk.
                let allFrames = try CargoCodec.encode(.chunk(id: id, bytes: bytes), maxFramePayloadBytes: maxFramePayloadBytes)
                guard !allFrames.isEmpty else { continue }

                let key = Hex.encode(id)
                var cursor = Int(from.sendState.nextPartByChunkIdHex[key] ?? 0) % allFrames.count
                var partsSent = 0

                while remainingItems > 0 && remainingBytes > 0 && partsSent < allFrames.count {
                    let frame = allFrames[cursor]
                    if frame.sizeBytes > remainingBytes { break }

                    try from.link.send(frame)
                    remainingBytes -= frame.sizeBytes
                    remainingItems -= 1
                    sentFrames += 1
                    partsSent += 1

                    if sentFrames % 3 == 0, frame.sizeBytes <= remainingBytes, remainingItems > 0 {
                        try from.link.send(frame)
                        remainingBytes -= frame.sizeBytes
                        remainingItems -= 1
                        sentFrames += 1
                        dupFrames += 1
                    }

                    cursor = (cursor + 1) % allFrames.count
                }

                from.sendState.nextPartByChunkIdHex[key] = UInt16(cursor)
            }
        }

        var receivedFrames = 0
        var seenChunkPartsThisSession: Set<String> = []
        while let frame = try to.link.receive() {
            try handle(frame: frame, receiver: to, sender: from, now: now, seenChunkPartsThisSession: &seenChunkPartsThisSession)
            receivedFrames += 1
        }

        return SessionReport(
            plannedCount: plan.count,
            sentFrames: sentFrames,
            receivedFrames: receivedFrames,
            duplicateFrames: dupFrames
        )
    }

    private static func handle(
        frame: Frame,
        receiver: SimPeer,
        sender: SimPeer,
        now: Date,
        seenChunkPartsThisSession: inout Set<String>
    ) throws {
        let fragment = try CargoCodec.decode(frame)
        switch fragment {
        case let .metadata(type, id, bytes):
            switch CargoCodec.FrameType(rawValue: type) {
            case .manifest:
                try receiver.store.recordReceived(item: InboxItem(id: id, kind: .manifest, payload: bytes, receivedAt: now))
                receiver.receiveState.receivedManifestIds.insert(Hex.encode(id))
            case .envelope:
                try receiver.store.recordReceived(item: InboxItem(id: id, kind: .envelope, payload: bytes, receivedAt: now))
                receiver.receiveState.receivedEnvelopeIds.insert(Hex.encode(id))
            case .receipt:
                try receiver.store.recordReceived(item: InboxItem(id: id, kind: .receipt, payload: bytes, receivedAt: now))
                receiver.receiveState.receivedReceiptIds.insert(Hex.encode(id))
            default:
                break
            }

        case let .chunkPart(id, partIndex, partCount, bytes):
            let key = "\(Hex.encode(id)):\(partIndex)"
            if seenChunkPartsThisSession.contains(key) {
                return
            }
            seenChunkPartsThisSession.insert(key)

            let chunkKey = Hex.encode(id)
            var partial = receiver.receiveState.partialByChunkIdHex[chunkKey] ?? .init(partCount: partCount, parts: [:])
            if partial.partCount != partCount {
                // Keep the first observed partCount.
                return
            }
            if partial.parts[partIndex] == nil {
                partial.parts[partIndex] = bytes
            }
            receiver.receiveState.partialByChunkIdHex[chunkKey] = partial

            if partial.parts.count == Int(partCount) {
                var full = Data()
                for i in 0..<partCount {
                    guard let part = partial.parts[i] else { return }
                    full.append(part)
                }
                try receiver.store.putChunk(id: id, bytes: full, receivedAt: now)
                receiver.receiveState.partialByChunkIdHex[chunkKey] = nil
            }
        }
    }
}
