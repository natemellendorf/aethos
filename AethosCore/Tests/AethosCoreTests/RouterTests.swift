import Foundation
import Testing
@testable import AethosCore

@Test
func manifestAndEnvelopePlannedBeforeChunks() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let router = Router(store: store)

    let now = Date(timeIntervalSince1970: 1_000)
    let payload = Data(repeating: 0xAB, count: Chunking.chunkSize + 1)
    let chunks = Chunking.chunk(payload)
    for c in chunks {
        try store.putChunk(id: c.id, bytes: c.bytes, receivedAt: now)
    }

    let manifest = Chunking.buildManifest(for: payload)
    let manifestBytes = CanonicalEncoderV1.encode(manifest)
    let manifestId = AethosIDs.manifestId(from: manifest)

    let envelope = EnvelopeV1(toWayfarerId: Data(repeating: 0xAA, count: 32), manifestId: manifestId, body: Data([0x01]))
    let envelopeBytes = CanonicalEncoderV1.encode(envelope)

    try store.enqueue(item: OutboxItem(id: Data([0x10]), kind: .manifest, payload: manifestBytes, enqueuedAt: now))
    try store.enqueue(item: OutboxItem(id: Data([0x11]), kind: .envelope, payload: envelopeBytes, enqueuedAt: now))

    let plan = try router.planNextSession(budget: SessionBudget(maxBytes: 1_000_000, maxItems: 10), now: now)
    #expect(plan.count >= 3)

    // First two are metadata, chunks come after.
    #expect(plan[0].priority == .metadata)
    #expect(plan[1].priority == .metadata)
    #expect(plan.dropFirst(2).contains { if case .chunk = $0 { true } else { false } })
}

@Test
func smallBudgetFitsOnlyMetadata() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let router = Router(store: store)
    let now = Date(timeIntervalSince1970: 1_000)

    let payload = Data(repeating: 0xAB, count: Chunking.chunkSize + 1)
    let chunks = Chunking.chunk(payload)
    for c in chunks {
        try store.putChunk(id: c.id, bytes: c.bytes, receivedAt: now)
    }

    let manifest = Chunking.buildManifest(for: payload)
    let manifestBytes = CanonicalEncoderV1.encode(manifest)
    let manifestId = AethosIDs.manifestId(from: manifest)
    let envelope = EnvelopeV1(toWayfarerId: Data(repeating: 0xAA, count: 32), manifestId: manifestId, body: Data([0x01]))
    let envelopeBytes = CanonicalEncoderV1.encode(envelope)

    try store.enqueue(item: OutboxItem(id: Data([0x10]), kind: .manifest, payload: manifestBytes, enqueuedAt: now))
    try store.enqueue(item: OutboxItem(id: Data([0x11]), kind: .envelope, payload: envelopeBytes, enqueuedAt: now))

    let metadataBytes = manifestBytes.count + envelopeBytes.count
    let plan = try router.planNextSession(
        budget: SessionBudget(maxBytes: metadataBytes, maxItems: 10),
        now: now
    )

    #expect(plan.count == 2)
    #expect(plan.allSatisfy { $0.priority == .metadata })
}

@Test
func chunksAreRoundRobinAcrossTransfers() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let router = Router(store: store)
    let now = Date(timeIntervalSince1970: 1_000)

    func seedTransfer(idByte: UInt8, enqueuedAt: Date, payloadByte: UInt8) throws -> (manifestBytes: Data, envelopeBytes: Data, chunkIds: [Data]) {
        let payload = Data(repeating: payloadByte, count: Chunking.chunkSize + 1)
        let chunks = Chunking.chunk(payload)
        for c in chunks {
            try store.putChunk(id: c.id, bytes: c.bytes, receivedAt: now)
        }
        let manifest = Chunking.buildManifest(for: payload)
        let manifestBytes = CanonicalEncoderV1.encode(manifest)
        let manifestId = AethosIDs.manifestId(from: manifest)
        let envelope = EnvelopeV1(toWayfarerId: Data(repeating: 0xAA, count: 32), manifestId: manifestId, body: Data([idByte]))
        let envelopeBytes = CanonicalEncoderV1.encode(envelope)

        try store.enqueue(item: OutboxItem(id: Data([idByte, 0x00]), kind: .manifest, payload: manifestBytes, enqueuedAt: enqueuedAt))
        try store.enqueue(item: OutboxItem(id: Data([idByte, 0x01]), kind: .envelope, payload: envelopeBytes, enqueuedAt: enqueuedAt))

        return (manifestBytes, envelopeBytes, chunks.map { $0.id })
    }

    let t1 = try seedTransfer(idByte: 0x01, enqueuedAt: Date(timeIntervalSince1970: 100), payloadByte: 0x10)
    let t2 = try seedTransfer(idByte: 0x02, enqueuedAt: Date(timeIntervalSince1970: 200), payloadByte: 0x20)

    let metadataBytes = t1.manifestBytes.count + t1.envelopeBytes.count + t2.manifestBytes.count + t2.envelopeBytes.count
    let budget = SessionBudget(maxBytes: metadataBytes + Chunking.chunkSize * 2 + 100, maxItems: 10)
    let plan = try router.planNextSession(budget: budget, now: now)

    let chunkItems = plan.compactMap { item -> Data? in
        if case let .chunk(id, _) = item { return id }
        return nil
    }
    #expect(chunkItems.count >= 2)

    // First two chunks should be from different transfers (round-robin).
    #expect(chunkItems[0] != chunkItems[1])
    #expect(Set([chunkItems[0], chunkItems[1]]).isSubset(of: Set(t1.chunkIds + t2.chunkIds)))
}

@Test
func receiptHasPriorityOverChunks() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let router = Router(store: store)
    let now = Date(timeIntervalSince1970: 1_000)

    // Seed one transfer with at least one chunk.
    let payload = Data(repeating: 0xAB, count: Chunking.chunkSize + 1)
    let chunks = Chunking.chunk(payload)
    for c in chunks {
        try store.putChunk(id: c.id, bytes: c.bytes, receivedAt: now)
    }
    let manifest = Chunking.buildManifest(for: payload)
    let manifestBytes = CanonicalEncoderV1.encode(manifest)
    let manifestId = AethosIDs.manifestId(from: manifest)
    let envelope = EnvelopeV1(toWayfarerId: Data(repeating: 0xAA, count: 32), manifestId: manifestId, body: Data([0x01]))
    let envelopeBytes = CanonicalEncoderV1.encode(envelope)
    let envelopeId = AethosIDs.envelopeId(canonicalBytes: envelopeBytes)

    let receipt = ReceiptV1(envelopeId: envelopeId, manifestId: manifestId, receivedAtUnixMs: 1, signature: Data())
    let receiptBytes = CanonicalEncoderV1.encode(receipt)

    try store.enqueue(item: OutboxItem(id: Data([0x10]), kind: .manifest, payload: manifestBytes, enqueuedAt: now))
    try store.enqueue(item: OutboxItem(id: Data([0x11]), kind: .envelope, payload: envelopeBytes, enqueuedAt: now))
    try store.enqueue(item: OutboxItem(id: Data([0x12]), kind: .receipt, payload: receiptBytes, enqueuedAt: now))

    let plan = try router.planNextSession(budget: SessionBudget(maxBytes: 1_000_000, maxItems: 10), now: now)
    #expect(plan.first?.priority == .receipt)
}
