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

    public init(name: String, store: AethosStore, link: Link) {
        self.name = name
        self.store = store
        self.router = Router(store: store)
        self.link = link
    }
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
    // Placeholder cargo encoding:
    // payload := [cargoType: UInt8] + raw bytes
    // id := sha256(payload)
    private enum CargoType: UInt8 {
        case envelope = 1
        case manifest = 2
        case chunk = 3
        case receipt = 4
    }

    public static func run(from: SimPeer, to: SimPeer, budget: SessionBudget, now: Date) throws -> SessionReport {
        let plan = try from.router.planNextSession(budget: budget, now: now)
        var sent = 0
        var dup = 0

        for (i, item) in plan.enumerated() {
            let frame = encode(item)
            try from.link.send(frame)
            sent += 1

            // Intentional duplication: every 3rd item is resent.
            if i % 3 == 0 {
                try from.link.send(frame)
                sent += 1
                dup += 1
            }
        }

        var received = 0
        while let frame = try to.link.receive() {
            try handle(frame: frame, receiver: to, sender: from, now: now)
            received += 1
        }

        return SessionReport(plannedCount: plan.count, sentFrames: sent, receivedFrames: received, duplicateFrames: dup)
    }

    private static func encode(_ item: CargoItem) -> Frame {
        let payload: Data
        let type: UInt8

        switch item {
        case let .envelope(bytes):
            payload = Data([CargoType.envelope.rawValue]) + bytes
            type = CargoType.envelope.rawValue
        case let .manifest(bytes):
            payload = Data([CargoType.manifest.rawValue]) + bytes
            type = CargoType.manifest.rawValue
        case let .receipt(bytes):
            payload = Data([CargoType.receipt.rawValue]) + bytes
            type = CargoType.receipt.rawValue
        case let .chunk(id, bytes):
            // Include the chunkId explicitly to allow reconstruction without inspecting payload.
            payload = Data([CargoType.chunk.rawValue]) + id + bytes
            type = CargoType.chunk.rawValue
        }

        let id = AethosIDs.sha256(payload)
        return Frame(type: type, id: id, partIndex: 0, partCount: 1, payload: payload)
    }

    private static func handle(frame: Frame, receiver: SimPeer, sender: SimPeer, now: Date) throws {
        // Minimal handler based on placeholder encoding.
        guard frame.partCount == 1, frame.partIndex == 0 else { return }
        guard let cargoType = frame.payload.first else { return }

        switch cargoType {
        case CargoType.chunk.rawValue:
            // [type][chunkId:32][bytes...]
            guard frame.payload.count >= 1 + 32 else { return }
            let chunkId = frame.payload.subdata(in: 1..<33)
            let bytes = frame.payload.subdata(in: 33..<frame.payload.count)
            try receiver.store.putChunk(id: chunkId, bytes: bytes, receivedAt: now)

        case CargoType.manifest.rawValue:
            let bytes = frame.payload.subdata(in: 1..<frame.payload.count)
            let id = AethosIDs.manifestId(canonicalBytes: bytes)
            try receiver.store.recordReceived(item: InboxItem(id: id, kind: .manifest, payload: bytes, receivedAt: now))

            // Enqueue a receipt back to the sender.
            let receiptBytes = Data("manifestAck:\(Hex.encode(id))".utf8)
            let receiptId = AethosIDs.sha256(receiptBytes)
            try receiver.store.enqueue(item: OutboxItem(id: receiptId, kind: .receipt, payload: receiptBytes, enqueuedAt: now))

        case CargoType.envelope.rawValue:
            let bytes = frame.payload.subdata(in: 1..<frame.payload.count)
            let id = AethosIDs.envelopeId(canonicalBytes: bytes)
            try receiver.store.recordReceived(item: InboxItem(id: id, kind: .envelope, payload: bytes, receivedAt: now))

            let receiptBytes = Data("envelopeAck:\(Hex.encode(id))".utf8)
            let receiptId = AethosIDs.sha256(receiptBytes)
            try receiver.store.enqueue(item: OutboxItem(id: receiptId, kind: .receipt, payload: receiptBytes, enqueuedAt: now))

        case CargoType.receipt.rawValue:
            let bytes = frame.payload.subdata(in: 1..<frame.payload.count)
            let id = AethosIDs.sha256(bytes)
            try receiver.store.recordReceived(item: InboxItem(id: id, kind: .receipt, payload: bytes, receivedAt: now))

            // Ack simulation: if this is an envelope ack, mark it on the sender.
            if let s = String(data: bytes, encoding: .utf8), s.hasPrefix("envelopeAck:") {
                let hex = String(s.dropFirst("envelopeAck:".count))
                if let envId = Hex.decode(hex) {
                    try sender.store.markAcked(envelopeId: envId)
                }
            }

        default:
            return
        }
    }
}
