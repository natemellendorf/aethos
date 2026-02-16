import Foundation

public final class Router {
    public enum RouterError: Swift.Error, Equatable {
        case invalidCanonicalType
        case missingChunkBytes(id: Data)
    }

    private struct PendingTransfer {
        let manifestId: Data
        let enqueuedAt: Date
        var manifestBytes: Data?
        var envelopeBytes: Data?
        var chunkOrder: [Data]
        var nextChunkIndex: Int
    }

    private let store: AethosStore

    public init(store: AethosStore) {
        self.store = store
    }

    public func planNextSession(budget: SessionBudget, now: Date) throws -> [CargoItem] {
        var plan: [CargoItem] = []
        plan.reserveCapacity(min(budget.maxItems, 64))

        var usedBytes = 0

        func canAdd(_ item: CargoItem) -> Bool {
            if plan.count + 1 > budget.maxItems { return false }
            if usedBytes + item.sizeBytes > budget.maxBytes { return false }
            return true
        }

        func addIfFits(_ item: CargoItem) {
            guard canAdd(item) else { return }
            plan.append(item)
            usedBytes += item.sizeBytes
        }

        let outbox = try store.peekQueuedOutbox(limit: 10_000)
        let activeOutbox = outbox.filter { $0.expiresAt.map { $0 > now } ?? true }

        // Priority 1: receipts
        for item in activeOutbox where item.kind == .receipt {
            let cargo = CargoItem.receipt(item.payload)
            if !canAdd(cargo) { return plan }
            addIfFits(cargo)
        }

        // Priority 2: inventory requests
        for item in activeOutbox where item.kind == .inventoryRequest {
            let cargo = CargoItem.inventoryRequest(item.payload)
            if !canAdd(cargo) { return plan }
            addIfFits(cargo)
        }

        // Priority 3: inventory advertisements
        for item in activeOutbox where item.kind == .inventory {
            let cargo = CargoItem.inventory(item.payload)
            if !canAdd(cargo) { return plan }
            addIfFits(cargo)
        }

        // Priority 3b: messages (same class as inventory; keep ahead of metadata/chunks)
        for item in activeOutbox where item.kind == .message {
            let cargo = CargoItem.message(item.payload)
            if !canAdd(cargo) { return plan }
            addIfFits(cargo)
        }

        // Build pending transfers keyed by manifestId.
        var transfers: [Data: PendingTransfer] = [:]

        let nowMs = Int64(now.timeIntervalSince1970 * 1000)

        // First, manifests define chunk ordering.
        for item in activeOutbox where item.kind == .manifest {
            let manifestId = AethosIDs.manifestId(canonicalBytes: item.payload)
            let parsed = try CanonicalParserV1.parseManifest(canonical: item.payload)

            let rotation = chunkRotationOffset(nowMs: nowMs, manifestId: manifestId, count: parsed.chunkIds.count)
            let chunkOrder = rotate(parsed.chunkIds, by: rotation)

            let t = PendingTransfer(
                manifestId: manifestId,
                enqueuedAt: item.enqueuedAt,
                manifestBytes: item.payload,
                envelopeBytes: nil,
                chunkOrder: chunkOrder,
                nextChunkIndex: 0
            )
            transfers[manifestId] = t
        }

        // Envelopes reference manifests; they may arrive without the manifest outbox item.
        for item in activeOutbox where item.kind == .envelope {
            let parsed = try CanonicalParserV1.parseEnvelope(canonical: item.payload)
            let manifestId = parsed.manifestId

            if var existing = transfers[manifestId] {
                if existing.envelopeBytes == nil {
                    existing.envelopeBytes = item.payload
                }
                transfers[manifestId] = existing
            } else {
                // No manifest known yet; keep as a transfer with no chunks.
                transfers[manifestId] = PendingTransfer(
                    manifestId: manifestId,
                    enqueuedAt: item.enqueuedAt,
                    manifestBytes: nil,
                    envelopeBytes: item.payload,
                    chunkOrder: [],
                    nextChunkIndex: 0
                )
            }
        }

        // Priority 4: metadata (manifest/envelope), stable by enqueue time.
        var orderedTransfers = transfers.values.sorted { $0.enqueuedAt < $1.enqueuedAt }
        for t in orderedTransfers {
            if let manifestBytes = t.manifestBytes {
                let cargo = CargoItem.manifest(manifestBytes)
                if !canAdd(cargo) { return plan }
                addIfFits(cargo)
            }
            if let envelopeBytes = t.envelopeBytes {
                let cargo = CargoItem.envelope(envelopeBytes)
                if !canAdd(cargo) { return plan }
                addIfFits(cargo)
            }
        }

        // Priority 5: chunks, round-robin across transfers.
        // Filter to transfers that have chunkIds.
        orderedTransfers = orderedTransfers.filter { !$0.chunkOrder.isEmpty }
        var idx = 0
        while !orderedTransfers.isEmpty {
            if plan.count >= budget.maxItems { break }

            if idx >= orderedTransfers.count { idx = 0 }
            var t = orderedTransfers[idx]
            if t.nextChunkIndex >= t.chunkOrder.count {
                orderedTransfers.remove(at: idx)
                continue
            }

            let chunkId = t.chunkOrder[t.nextChunkIndex]
            guard let bytes = try store.getChunk(id: chunkId) else {
                throw RouterError.missingChunkBytes(id: chunkId)
            }

            let cargo = CargoItem.chunk(id: chunkId, bytes: bytes)
            if !canAdd(cargo) { break }
            addIfFits(cargo)

            t.nextChunkIndex += 1
            orderedTransfers[idx] = t
            idx += 1
        }

        return plan
    }

    private func chunkRotationOffset(nowMs: Int64, manifestId: Data, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let seed = Int((nowMs % Int64(Int.max)) + Int64(manifestId.first ?? 0))
        let m = seed % count
        return m >= 0 ? m : (m + count)
    }

    private func rotate(_ items: [Data], by offset: Int) -> [Data] {
        guard !items.isEmpty else { return [] }
        let o = offset % items.count
        if o == 0 { return items }
        return Array(items[o...]) + Array(items[..<o])
    }
}

private enum CanonicalParserV1 {
    struct ParsedManifest {
        let chunkIds: [Data]
    }

    struct ParsedEnvelope {
        let manifestId: Data
    }

    static func parseManifest(canonical: Data) throws -> ParsedManifest {
        let fields = try parseFields(expectedType: CanonicalEncoderV1.TypeDiscriminator.manifest.rawValue, canonical: canonical)
        guard let raw = fields[CanonicalEncoderV1.ManifestField.chunkIds.rawValue] else {
            return ParsedManifest(chunkIds: [])
        }
        return ParsedManifest(chunkIds: try parseArrayOfBytes(raw))
    }

    static func parseEnvelope(canonical: Data) throws -> ParsedEnvelope {
        let fields = try parseFields(expectedType: CanonicalEncoderV1.TypeDiscriminator.envelope.rawValue, canonical: canonical)
        guard let raw = fields[CanonicalEncoderV1.EnvelopeField.manifestId.rawValue] else {
            return ParsedEnvelope(manifestId: Data())
        }
        return ParsedEnvelope(manifestId: raw)
    }

    private static func parseFields(expectedType: UInt8, canonical: Data) throws -> [UInt8: Data] {
        var r = Reader(canonical)
        guard r.readUInt8() != nil else { throw Router.RouterError.invalidCanonicalType }
        guard let type = r.readUInt8(), type == expectedType else { throw Router.RouterError.invalidCanonicalType }

        var map: [UInt8: Data] = [:]
        while !r.isAtEnd {
            guard let fieldId = r.readUInt8() else { break }
            guard let len = r.readUInt32() else { throw Router.RouterError.invalidCanonicalType }
            guard let bytes = r.readData(count: Int(len)) else { throw Router.RouterError.invalidCanonicalType }
            map[fieldId] = bytes
        }
        return map
    }

    private static func parseArrayOfBytes(_ raw: Data) throws -> [Data] {
        var r = Reader(raw)
        guard let count = r.readUInt32() else { throw Router.RouterError.invalidCanonicalType }
        var out: [Data] = []
        out.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let len = r.readUInt32() else { throw Router.RouterError.invalidCanonicalType }
            guard let bytes = r.readData(count: Int(len)) else { throw Router.RouterError.invalidCanonicalType }
            out.append(bytes)
        }
        return out
    }

    private struct Reader {
        private let data: Data
        private var offset: Int = 0

        init(_ data: Data) {
            self.data = data
        }

        var isAtEnd: Bool { offset >= data.count }

        mutating func readUInt8() -> UInt8? {
            guard offset + 1 <= data.count else { return nil }
            let v = data[offset]
            offset += 1
            return v
        }

        mutating func readUInt32() -> UInt32? {
            guard offset + 4 <= data.count else { return nil }
            let slice = data[offset..<offset + 4]
            offset += 4
            // Avoid alignment traps by decoding manually.
            var v: UInt32 = 0
            for b in slice {
                v = (v << 8) | UInt32(b)
            }
            return v
        }

        mutating func readData(count: Int) -> Data? {
            guard count >= 0, offset + count <= data.count else { return nil }
            let slice = data[offset..<offset + count]
            offset += count
            return Data(slice)
        }
    }
}
