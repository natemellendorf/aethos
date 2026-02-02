import Foundation

public struct SimPeer {
    public let name: String
    public let store: AethosStore
    public let router: Router

    public init(name: String, store: AethosStore) {
        self.name = name
        self.store = store
        self.router = Router(store: store)
    }
}

public struct SessionReport: Equatable {
    public let sentCount: Int
    public let deliveredCount: Int
    public let duplicateCount: Int

    public init(sentCount: Int, deliveredCount: Int, duplicateCount: Int) {
        self.sentCount = sentCount
        self.deliveredCount = deliveredCount
        self.duplicateCount = duplicateCount
    }
}

public struct SimLink {
    public init() {}

    public func runSession(from: SimPeer, to: SimPeer, budget: SessionBudget, now: Date) throws -> SessionReport {
        let plan = try from.router.planNextSession(budget: budget, now: now)
        var delivered = 0
        var duplicates = 0

        func transmit(_ item: CargoItem, duplicate: Bool) throws {
            switch item {
            case let .chunk(id, bytes):
                try to.store.putChunk(id: id, bytes: bytes, receivedAt: now)
                delivered += 1

                // Idempotent ack: record a receipt-like marker in receiver inbox.
                // In MVP0 we only use receipts for planning priority.
                let receiptBytes = Data("chunk:\(Hex.encode(id))".utf8)
                let receiptId = AethosIDs.sha256(receiptBytes)
                try to.store.recordReceived(item: InboxItem(id: receiptId, kind: .receipt, payload: receiptBytes, receivedAt: now))
                if duplicate { duplicates += 1 }

            case let .manifest(bytes):
                let id = AethosIDs.manifestId(canonicalBytes: bytes)
                try to.store.recordReceived(item: InboxItem(id: id, kind: .manifest, payload: bytes, receivedAt: now))
                delivered += 1

                // Enqueue receipt back to sender.
                let receiptBytes = Data("manifestAck:\(Hex.encode(id))".utf8)
                let receiptId = AethosIDs.sha256(receiptBytes)
                try to.store.enqueue(item: OutboxItem(id: receiptId, kind: .receipt, payload: receiptBytes, enqueuedAt: now))

                if duplicate { duplicates += 1 }

            case let .envelope(bytes):
                let id = AethosIDs.envelopeId(canonicalBytes: bytes)
                try to.store.recordReceived(item: InboxItem(id: id, kind: .envelope, payload: bytes, receivedAt: now))
                delivered += 1

                // Enqueue receipt back to sender.
                let receiptBytes = Data("envelopeAck:\(Hex.encode(id))".utf8)
                let receiptId = AethosIDs.sha256(receiptBytes)
                try to.store.enqueue(item: OutboxItem(id: receiptId, kind: .receipt, payload: receiptBytes, enqueuedAt: now))

                if duplicate { duplicates += 1 }

            case let .receipt(bytes):
                // Receiver treats receipt as received metadata.
                let id = AethosIDs.sha256(bytes)
                try to.store.recordReceived(item: InboxItem(id: id, kind: .receipt, payload: bytes, receivedAt: now))
                delivered += 1

                if duplicate { duplicates += 1 }
            }
        }

        // Intentionally duplicate some items: every 3rd item is retransmitted once.
        for (i, item) in plan.enumerated() {
            try transmit(item, duplicate: false)
            if i % 3 == 0 {
                try transmit(item, duplicate: true)
            }
        }

        // Minimal ack simulation: if sender receives any receipt bytes mentioning an envelope id,
        // call markAcked on that id. This stops envelope resends if it was stored under that id.
        let receivedReceipts = try to.store.peekQueuedOutbox(limit: 10_000).filter { $0.kind == .receipt }
        for receipt in receivedReceipts {
            if let s = String(data: receipt.payload, encoding: .utf8), s.hasPrefix("envelopeAck:") {
                let hex = String(s.dropFirst("envelopeAck:".count))
                if let envId = Hex.decode(hex) {
                    try from.store.markAcked(envelopeId: envId)
                }
            }
        }

        return SessionReport(sentCount: plan.count, deliveredCount: delivered, duplicateCount: duplicates)
    }
}
