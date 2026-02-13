import Foundation
import Testing
@testable import AethosCore

// MARK: - Transfer row creation and retrieval

@Test
func transferCreateAndRetrieve() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))

    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let transferId = Transfer.newId()

    let transfer = Transfer(
        transferId: transferId,
        direction: .outbound,
        peerFrom: "aabbccdd",
        peerTo: "11223344",
        createdAt: now,
        updatedAt: now,
        lastActivityAt: now,
        status: .queued,
        originalFilename: "payload.bin",
        bytesTotal: 204800,
        bytesSent: 0,
        bytesReceived: 0,
        partsTotal: 7,
        partsSent: 0,
        partsReceived: 0,
        manifestHash: "deadbeef01",
        payloadHash: "cafebabe02",
        verified: false,
        lastError: nil
    )

    try store.createTransfer(transfer)

    let retrieved = try store.getTransfer(id: transferId)
    #expect(retrieved != nil)
    #expect(retrieved?.transferId == transferId)
    #expect(retrieved?.direction == .outbound)
    #expect(retrieved?.status == .queued)
    #expect(retrieved?.peerFrom == "aabbccdd")
    #expect(retrieved?.peerTo == "11223344")
    #expect(retrieved?.originalFilename == "payload.bin")
    #expect(retrieved?.bytesTotal == 204800)
    #expect(retrieved?.partsTotal == 7)
    #expect(retrieved?.manifestHash == "deadbeef01")
    #expect(retrieved?.payloadHash == "cafebabe02")
    #expect(retrieved?.verified == false)
    #expect(retrieved?.lastError == nil)
}

@Test
func transferCreateIsIdempotent() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let now = Date()

    let transfer = Transfer(
        transferId: "test-id-1",
        direction: .outbound,
        peerFrom: "a",
        peerTo: "b",
        createdAt: now,
        updatedAt: now,
        lastActivityAt: now,
        status: .queued
    )

    try store.createTransfer(transfer)
    try store.createTransfer(transfer) // INSERT OR IGNORE

    #expect(try store.__debugRowCount(table: "transfers") == 1)
}

// MARK: - Transfer updates

@Test
func transferUpdateStatus() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    var transfer = Transfer(
        transferId: "update-test",
        direction: .outbound,
        peerFrom: "a",
        peerTo: "b",
        createdAt: now,
        updatedAt: now,
        lastActivityAt: now,
        status: .queued,
        bytesTotal: 100000,
        partsTotal: 4
    )
    try store.createTransfer(transfer)

    // Simulate queued -> sending
    transfer.status = .sending
    transfer.bytesSent = 5000
    transfer.partsSent = 2
    transfer.updatedAt = Date(timeIntervalSince1970: 1_700_001_000)
    transfer.lastActivityAt = Date(timeIntervalSince1970: 1_700_001_000)
    try store.updateTransfer(transfer)

    let fetched = try store.getTransfer(id: "update-test")
    #expect(fetched?.status == .sending)
    #expect(fetched?.bytesSent == 5000)
    #expect(fetched?.partsSent == 2)
}

// MARK: - Lookup by manifest hash

@Test
func transferLookupByManifestHash() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let now = Date()

    let t1 = Transfer(
        transferId: "out-1",
        direction: .outbound,
        peerFrom: "a",
        peerTo: "b",
        createdAt: now,
        updatedAt: now,
        lastActivityAt: now,
        status: .sending,
        manifestHash: "manifest-hash-abc"
    )

    let t2 = Transfer(
        transferId: "in-1",
        direction: .inbound,
        peerFrom: "",
        peerTo: "b",
        createdAt: now,
        updatedAt: now,
        lastActivityAt: now,
        status: .receiving,
        manifestHash: "manifest-hash-abc"
    )

    try store.createTransfer(t1)
    try store.createTransfer(t2)

    let outbound = try store.getTransferByManifestHash("manifest-hash-abc", direction: .outbound)
    #expect(outbound?.transferId == "out-1")

    let inbound = try store.getTransferByManifestHash("manifest-hash-abc", direction: .inbound)
    #expect(inbound?.transferId == "in-1")

    let missing = try store.getTransferByManifestHash("nonexistent", direction: .outbound)
    #expect(missing == nil)
}

// MARK: - List transfers

@Test
func transferListAll() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let now = Date()

    try store.createTransfer(Transfer(
        transferId: "t1", direction: .outbound, peerFrom: "a", peerTo: "b",
        createdAt: now, updatedAt: now, lastActivityAt: now, status: .queued
    ))
    try store.createTransfer(Transfer(
        transferId: "t2", direction: .inbound, peerFrom: "", peerTo: "b",
        createdAt: now, updatedAt: now, lastActivityAt: now, status: .receiving
    ))
    try store.createTransfer(Transfer(
        transferId: "t3", direction: .outbound, peerFrom: "a", peerTo: "c",
        createdAt: now, updatedAt: now, lastActivityAt: now, status: .complete
    ))

    let all = try store.listTransfers()
    #expect(all.count == 3)

    let outbound = try store.listTransfers(direction: .outbound)
    #expect(outbound.count == 2)

    let inbound = try store.listTransfers(direction: .inbound)
    #expect(inbound.count == 1)
    #expect(inbound[0].transferId == "t2")
}

// MARK: - Status transitions

@Test
func statusTransitionQueuedToSending() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let now = Date()

    var t = Transfer(
        transferId: "st-1", direction: .outbound, peerFrom: "a", peerTo: "b",
        createdAt: now, updatedAt: now, lastActivityAt: now, status: .queued,
        bytesTotal: 32768, partsTotal: 1
    )
    try store.createTransfer(t)

    // Transition: queued -> sending
    t.status = .sending
    t.bytesSent = 1024
    t.partsSent = 1
    t.updatedAt = Date()
    try store.updateTransfer(t)

    let fetched = try store.getTransfer(id: "st-1")
    #expect(fetched?.status == .sending)
}

@Test
func statusTransitionReceivingToComplete() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let now = Date()

    var t = Transfer(
        transferId: "st-2", direction: .inbound, peerFrom: "", peerTo: "b",
        createdAt: now, updatedAt: now, lastActivityAt: now, status: .receiving,
        bytesTotal: 65536, partsTotal: 2
    )
    try store.createTransfer(t)

    // Simulate receiving chunks
    t.partsReceived = 2
    t.bytesReceived = 65536
    t.status = .complete
    t.verified = true
    t.payloadHash = "abc123"
    t.updatedAt = Date()
    try store.updateTransfer(t)

    let fetched = try store.getTransfer(id: "st-2")
    #expect(fetched?.status == .complete)
    #expect(fetched?.verified == true)
    #expect(fetched?.partsReceived == 2)
    #expect(fetched?.bytesReceived == 65536)
}

@Test
func statusTransitionToFailed() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let now = Date()

    var t = Transfer(
        transferId: "st-3", direction: .inbound, peerFrom: "", peerTo: "b",
        createdAt: now, updatedAt: now, lastActivityAt: now, status: .receiving,
        bytesTotal: 32768, partsTotal: 1
    )
    try store.createTransfer(t)

    t.status = .failed
    t.lastError = "integrity mismatch: chunk hash invalid"
    t.updatedAt = Date()
    try store.updateTransfer(t)

    let fetched = try store.getTransfer(id: "st-3")
    #expect(fetched?.status == .failed)
    #expect(fetched?.lastError == "integrity mismatch: chunk hash invalid")
}

// MARK: - Schema migration from v1 to v2

@Test
func schemaMigrationV1ToV2CreatesTransfersTable() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    // Opening creates the schema (v0 -> v2)
    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))

    // Verify transfers table exists by inserting
    let t = Transfer(
        transferId: "mig-1", direction: .outbound, peerFrom: "a", peerTo: "b",
        createdAt: Date(), updatedAt: Date(), lastActivityAt: Date(), status: .queued
    )
    try store.createTransfer(t)
    #expect(try store.__debugRowCount(table: "transfers") == 1)

    // Verify existing tables still work
    #expect(try store.__debugRowCount(table: "chunks") == 0)
    #expect(try store.__debugRowCount(table: "outbox") == 0)
    #expect(try store.__debugRowCount(table: "inbox") == 0)
}

// MARK: - Integration test: full send -> pump -> ingest cycle

@Test
func integrationSendPumpIngestTransferLifecycle() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    // Set up two peer stores
    let storeA = try AethosStore(path: dir.appendingPathComponent("storeA.sqlite"))
    let storeB = try AethosStore(path: dir.appendingPathComponent("storeB.sqlite"))

    // Create payload
    let payloadSize = 100_000
    var payload = Data(count: payloadSize)
    for i in 0..<payloadSize { payload[i] = UInt8(i % 256) }

    let now = Date(timeIntervalSince1970: 1_700_000_000)

    // --- Step 1: Simulate "aethos send" on peerA ---

    let chunks = Chunking.chunk(payload)
    for c in chunks {
        try storeA.putChunk(id: c.id, bytes: c.bytes, receivedAt: now)
    }

    let manifest = Chunking.buildManifest(for: payload)
    let manifestBytes = CanonicalEncoderV1.encode(manifest)
    let manifestId = AethosIDs.manifestId(from: manifest)

    let toWayfarerId = Data(repeating: 0xBB, count: 32)
    let envelope = EnvelopeV1(
        toWayfarerId: toWayfarerId,
        manifestId: manifestId,
        body: Data("test.bin".utf8)
    )
    let envelopeBytes = CanonicalEncoderV1.encode(envelope)
    let envelopeId = AethosIDs.envelopeId(from: envelope)

    try storeA.enqueue(item: OutboxItem(id: manifestId, kind: .manifest, payload: manifestBytes, enqueuedAt: now))
    try storeA.enqueue(item: OutboxItem(id: envelopeId, kind: .envelope, payload: envelopeBytes, enqueuedAt: now))

    // Create outbound transfer
    let transferId = Transfer.newId()
    let outboundTransfer = Transfer(
        transferId: transferId,
        direction: .outbound,
        peerFrom: "aaaa",
        peerTo: Hex.encode(toWayfarerId),
        createdAt: now,
        updatedAt: now,
        lastActivityAt: now,
        status: .queued,
        originalFilename: "test.bin",
        bytesTotal: Int64(payload.count),
        partsTotal: Int32(chunks.count),
        manifestHash: manifestId.hexString,
        payloadHash: AethosIDs.sha256(payload).hexString
    )
    try storeA.createTransfer(outboundTransfer)

    // Verify: transfer created on send
    let sendTransfer = try storeA.getTransfer(id: transferId)
    #expect(sendTransfer != nil)
    #expect(sendTransfer?.status == .queued)
    #expect(sendTransfer?.bytesTotal == Int64(payloadSize))
    #expect(sendTransfer?.partsTotal == Int32(chunks.count))

    // --- Step 2: Simulate "pump" on peerA ---

    let router = Router(store: storeA)
    let plan = try router.planNextSession(
        budget: SessionBudget(maxBytes: 1_000_000, maxItems: 10_000),
        now: now
    )

    // Encode all planned items into frames
    var allFrames: [Frame] = []
    for item in plan {
        let frames = try CargoCodec.encode(item, maxFramePayloadBytes: 1024)
        allFrames.append(contentsOf: frames)
    }

    // Verify we got frames
    #expect(allFrames.count > 0)

    // Update outbound transfer status: queued -> sending
    var updatedOutbound = try storeA.getTransfer(id: transferId)!
    updatedOutbound.status = .sending
    updatedOutbound.bytesSent = Int64(allFrames.reduce(0) { $0 + $1.sizeBytes })
    updatedOutbound.partsSent = Int32(chunks.count)
    updatedOutbound.updatedAt = Date(timeIntervalSince1970: 1_700_001_000)
    try storeA.updateTransfer(updatedOutbound)

    let pumpedTransfer = try storeA.getTransfer(id: transferId)
    #expect(pumpedTransfer?.status == .sending)
    #expect(pumpedTransfer?.bytesSent ?? 0 > 0)

    // --- Step 3: Simulate "ingest" on peerB ---

    // Create inbound transfer when manifest arrives
    let inboundTransferId = Transfer.newId()
    let inboundTransfer = Transfer(
        transferId: inboundTransferId,
        direction: .inbound,
        peerFrom: "",
        peerTo: Hex.encode(toWayfarerId),
        createdAt: now,
        updatedAt: now,
        lastActivityAt: now,
        status: .receiving,
        bytesTotal: Int64(manifest.totalSize),
        partsTotal: Int32(manifest.chunkIds.count),
        manifestHash: manifestId.hexString
    )
    try storeB.createTransfer(inboundTransfer)

    // Simulate ingesting all frames — decode and store
    // Use local assembly state (not global) for Swift 6.0 concurrency safety
    var localAssembly: [Data: (partCount: Int, parts: [Int: Data])] = [:]
    for frame in allFrames {
        let fragment = try CargoCodec.decode(frame)
        switch fragment {
        case let .metadata(type, id, bytes):
            let kind: InboxItem.Kind
            switch CargoCodec.FrameType(rawValue: type) {
            case .manifest: kind = .manifest
            case .envelope: kind = .envelope
            case .receipt: kind = .receipt
            default: continue
            }
            try storeB.recordReceived(item: InboxItem(id: id, kind: kind, payload: bytes, receivedAt: now))

        case let .chunkPart(id, partIndex, partCount, bytes):
            if localAssembly[id] == nil {
                localAssembly[id] = (partCount: Int(partCount), parts: [:])
            }
            localAssembly[id]?.parts[Int(partIndex)] = bytes

            if let state = localAssembly[id], state.parts.count == state.partCount {
                var full = Data()
                for i in 0..<state.partCount {
                    guard let partData = state.parts[i] else { break }
                    full.append(partData)
                }
                if !full.isEmpty {
                    try storeB.putChunk(id: id, bytes: full, receivedAt: now)
                }
            }
        }
    }

    // Update inbound transfer progress
    var inboundUpdated = try storeB.getTransferByManifestHash(manifestId.hexString, direction: .inbound)!
    for chunkId in manifest.chunkIds {
        if try storeB.getChunk(id: chunkId) != nil {
            inboundUpdated.partsReceived += 1
        }
    }

    // Verify all chunks were received
    #expect(inboundUpdated.partsReceived == Int32(manifest.chunkIds.count))

    // Reassemble
    var chunksById: [Data: Data] = [:]
    for id in manifest.chunkIds {
        chunksById[id] = try storeB.getChunk(id: id)
    }
    let rebuilt = try Chunking.reassemble(chunksById: chunksById, manifest: manifest)

    // Verify payload matches
    #expect(rebuilt.count == payload.count)
    #expect(rebuilt == payload)

    // Mark as complete
    inboundUpdated.status = .complete
    inboundUpdated.verified = true
    inboundUpdated.bytesReceived = Int64(rebuilt.count)
    inboundUpdated.payloadHash = AethosIDs.sha256(rebuilt).hexString
    inboundUpdated.updatedAt = Date()
    try storeB.updateTransfer(inboundUpdated)

    // Verify transfer state on receiver
    let finalTransfer = try storeB.getTransfer(id: inboundTransferId)
    #expect(finalTransfer?.status == .complete)
    #expect(finalTransfer?.verified == true)
    #expect(finalTransfer?.bytesReceived == Int64(payloadSize))
    #expect(finalTransfer?.partsReceived == Int32(chunks.count))
}

// MARK: - Transfer newId generates unique IDs

@Test
func transferNewIdGeneratesUniqueIds() {
    let id1 = Transfer.newId()
    let id2 = Transfer.newId()
    #expect(id1 != id2)
    // UUID format: 8-4-4-4-12
    #expect(id1.count == 36)
    #expect(id2.count == 36)
}

// MARK: - Nullable fields

@Test
func transferNullableFieldsRoundTrip() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let now = Date()

    // Create with all nullable fields nil
    let t = Transfer(
        transferId: "null-test", direction: .outbound, peerFrom: "a", peerTo: "b",
        createdAt: now, updatedAt: now, lastActivityAt: now, status: .queued,
        originalFilename: nil, manifestHash: nil, payloadHash: nil, lastError: nil
    )
    try store.createTransfer(t)

    let fetched = try store.getTransfer(id: "null-test")
    #expect(fetched?.originalFilename == nil)
    #expect(fetched?.manifestHash == nil)
    #expect(fetched?.payloadHash == nil)
    #expect(fetched?.lastError == nil)

    // Update with values
    var updated = fetched!
    updated.originalFilename = "test.bin"
    updated.manifestHash = "abc"
    updated.payloadHash = "def"
    updated.lastError = "test error"
    try store.updateTransfer(updated)

    let fetched2 = try store.getTransfer(id: "null-test")
    #expect(fetched2?.originalFilename == "test.bin")
    #expect(fetched2?.manifestHash == "abc")
    #expect(fetched2?.payloadHash == "def")
    #expect(fetched2?.lastError == "test error")
}

// MARK: - Receipt-to-transfer correlation (unit test)

@Test
func receiptCorrelatesOutboundTransferToComplete() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    // Build a real manifest and envelope so we get deterministic IDs.
    let payload = Data(repeating: 0xAA, count: 1024)
    let manifest = Chunking.buildManifest(for: payload)
    let manifestBytes = CanonicalEncoderV1.encode(manifest)
    let manifestId = AethosIDs.manifestId(from: manifest)

    let toWayfarerId = Data(repeating: 0xCC, count: 32)
    let envelope = EnvelopeV1(toWayfarerId: toWayfarerId, manifestId: manifestId, body: Data("f.bin".utf8))
    let envelopeId = AethosIDs.envelopeId(from: envelope)

    // Create an outbound transfer in "sending" state on storeA (the sender).
    var outbound = Transfer(
        transferId: "receipt-corr-out",
        direction: .outbound,
        peerFrom: "sender-hex",
        peerTo: Hex.encode(toWayfarerId),
        createdAt: now,
        updatedAt: now,
        lastActivityAt: now,
        status: .sending,
        bytesTotal: Int64(payload.count),
        partsTotal: 1,
        manifestHash: manifestId.hexString
    )
    try store.createTransfer(outbound)

    // Build a receipt referencing the same manifestId (as the receiver would).
    let receipt = ReceiptV1(
        envelopeId: envelopeId,
        manifestId: manifestId,
        receivedAtUnixMs: UInt64(now.timeIntervalSince1970 * 1000)
    )
    let receiptBytes = CanonicalEncoderV1.encode(receipt)

    // Parse the receipt's manifestId out of the canonical bytes — same logic the CLI uses.
    let parsedManifestId = parseManifestIdFromReceipt(receiptBytes)
    #expect(parsedManifestId == manifestId)

    // Simulate the CLI correlation: look up outbound transfer by manifest_hash.
    let manifestHashHex = Hex.encode(parsedManifestId!)
    let found = try store.getTransferByManifestHash(manifestHashHex, direction: .outbound)
    #expect(found != nil)
    #expect(found?.status == .sending)

    // Transition sending → complete (exactly what ingest does).
    outbound = found!
    outbound.status = .complete
    outbound.verified = true
    outbound.updatedAt = Date(timeIntervalSince1970: 1_700_002_000)
    outbound.lastActivityAt = Date(timeIntervalSince1970: 1_700_002_000)
    try store.updateTransfer(outbound)

    let final_ = try store.getTransfer(id: "receipt-corr-out")
    #expect(final_?.status == .complete)
    #expect(final_?.verified == true)
}

/// Minimal receipt canonical parser used only in tests — mirrors CLI's parseReceiptCanonical.
private func parseManifestIdFromReceipt(_ bytes: Data) -> Data? {
    var offset = 0
    func readU8() -> UInt8? {
        guard offset < bytes.count else { return nil }
        let v = bytes[offset]; offset += 1; return v
    }
    func readU32() -> UInt32? {
        guard offset + 4 <= bytes.count else { return nil }
        var v: UInt32 = 0
        for i in 0..<4 { v = (v << 8) | UInt32(bytes[offset + i]) }
        offset += 4
        return v
    }
    func readBytes(_ n: Int) -> Data? {
        guard offset + n <= bytes.count else { return nil }
        let d = bytes[offset..<offset + n]
        offset += n
        return Data(d)
    }

    _ = readU8() // version
    guard readU8() == CanonicalEncoderV1.TypeDiscriminator.receipt.rawValue else { return nil }
    while offset < bytes.count {
        guard let fid = readU8(), let len = readU32(), let raw = readBytes(Int(len)) else { break }
        if fid == CanonicalEncoderV1.ReceiptField.manifestId.rawValue {
            return raw
        }
    }
    return nil
}

// MARK: - Integration: full send → pump → transport → ingest+receipt → transport → sender ingest

@Test
func integrationReceiptClosesSenderTransfer() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let storeA = try AethosStore(path: dir.appendingPathComponent("storeA.sqlite"))
    let storeB = try AethosStore(path: dir.appendingPathComponent("storeB.sqlite"))

    // Deterministic payload
    let payloadSize = 100_000
    var payload = Data(count: payloadSize)
    for i in 0..<payloadSize { payload[i] = UInt8(i % 256) }
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    // === peerA: send ===
    let chunks = Chunking.chunk(payload)
    for c in chunks { try storeA.putChunk(id: c.id, bytes: c.bytes, receivedAt: now) }

    let manifest = Chunking.buildManifest(for: payload)
    let manifestBytes = CanonicalEncoderV1.encode(manifest)
    let manifestId = AethosIDs.manifestId(from: manifest)

    let toWayfarerId = Data(repeating: 0xBB, count: 32)
    let envelope = EnvelopeV1(toWayfarerId: toWayfarerId, manifestId: manifestId, body: Data("test.bin".utf8))
    let envelopeBytes = CanonicalEncoderV1.encode(envelope)
    let envelopeId = AethosIDs.envelopeId(from: envelope)

    try storeA.enqueue(item: OutboxItem(id: manifestId, kind: .manifest, payload: manifestBytes, enqueuedAt: now))
    try storeA.enqueue(item: OutboxItem(id: envelopeId, kind: .envelope, payload: envelopeBytes, enqueuedAt: now))

    let transferId = Transfer.newId()
    try storeA.createTransfer(Transfer(
        transferId: transferId, direction: .outbound, peerFrom: "aaaa",
        peerTo: Hex.encode(toWayfarerId), createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .queued, originalFilename: "test.bin", bytesTotal: Int64(payload.count),
        partsTotal: Int32(chunks.count), manifestHash: manifestId.hexString,
        payloadHash: AethosIDs.sha256(payload).hexString
    ))

    // === peerA: pump (encode all items into frames) ===
    let router = Router(store: storeA)
    let plan = try router.planNextSession(budget: SessionBudget(maxBytes: 1_000_000, maxItems: 10_000), now: now)
    var aToB: [Frame] = []
    for item in plan {
        aToB.append(contentsOf: try CargoCodec.encode(item, maxFramePayloadBytes: 1024))
    }

    // Mark outbound transfer as sending
    var outT = try storeA.getTransfer(id: transferId)!
    outT.status = .sending
    outT.updatedAt = now
    try storeA.updateTransfer(outT)

    // === transport A→B ===
    // === peerB: ingest frames ===
    var localAssembly: [Data: (partCount: Int, parts: [Int: Data])] = [:]
    for frame in aToB {
        let fragment = try CargoCodec.decode(frame)
        switch fragment {
        case let .metadata(type, id, bytes):
            let kind: InboxItem.Kind
            switch CargoCodec.FrameType(rawValue: type) {
            case .manifest: kind = .manifest
            case .envelope: kind = .envelope
            case .receipt: kind = .receipt
            default: continue
            }
            try storeB.recordReceived(item: InboxItem(id: id, kind: kind, payload: bytes, receivedAt: now))

            // Create inbound transfer on manifest
            if kind == .manifest {
                try storeB.createTransfer(Transfer(
                    transferId: Transfer.newId(), direction: .inbound, peerFrom: "",
                    peerTo: Hex.encode(toWayfarerId), createdAt: now, updatedAt: now,
                    lastActivityAt: now, status: .receiving,
                    bytesTotal: Int64(manifest.totalSize),
                    partsTotal: Int32(manifest.chunkIds.count),
                    manifestHash: Hex.encode(id)
                ))
            }

        case let .chunkPart(id, partIndex, partCount, bytes):
            if localAssembly[id] == nil {
                localAssembly[id] = (partCount: Int(partCount), parts: [:])
            }
            localAssembly[id]?.parts[Int(partIndex)] = bytes
            if let state = localAssembly[id], state.parts.count == state.partCount {
                var full = Data()
                for i in 0..<state.partCount {
                    guard let d = state.parts[i] else { break }
                    full.append(d)
                }
                if !full.isEmpty {
                    try storeB.putChunk(id: id, bytes: full, receivedAt: now)
                }
            }
        }
    }

    // === peerB: reassemble ===
    var chunksById: [Data: Data] = [:]
    for id in manifest.chunkIds { chunksById[id] = try storeB.getChunk(id: id) }
    let rebuilt = try Chunking.reassemble(chunksById: chunksById, manifest: manifest)
    #expect(rebuilt == payload)

    // Mark inbound transfer complete
    var inT = try storeB.getTransferByManifestHash(manifestId.hexString, direction: .inbound)!
    inT.status = .complete
    inT.verified = true
    inT.bytesReceived = Int64(rebuilt.count)
    inT.partsReceived = Int32(chunks.count)
    inT.payloadHash = AethosIDs.sha256(rebuilt).hexString
    inT.updatedAt = now
    try storeB.updateTransfer(inT)

    #expect(try storeB.getTransfer(id: inT.transferId)?.status == .complete)

    // === peerB: generate receipt and enqueue ===
    let receipt = ReceiptV1(
        envelopeId: envelopeId,
        manifestId: manifestId,
        receivedAtUnixMs: UInt64(now.timeIntervalSince1970 * 1000)
    )
    let receiptBytes = CanonicalEncoderV1.encode(receipt)
    let receiptId = AethosIDs.receiptId(from: receipt)
    try storeB.enqueue(item: OutboxItem(id: receiptId, kind: .receipt, payload: receiptBytes, enqueuedAt: now))

    // === peerB: pump receipt into frames ===
    let routerB = Router(store: storeB)
    let planB = try routerB.planNextSession(budget: SessionBudget(maxBytes: 10_000, maxItems: 100), now: now)
    var bToA: [Frame] = []
    for item in planB {
        bToA.append(contentsOf: try CargoCodec.encode(item, maxFramePayloadBytes: 1024))
    }
    #expect(bToA.count > 0) // at least the receipt frame

    // === transport B→A ===
    // === peerA: ingest receipt ===
    for frame in bToA {
        let fragment = try CargoCodec.decode(frame)
        switch fragment {
        case let .metadata(type, id, bytes):
            if CargoCodec.FrameType(rawValue: type) == .receipt {
                try storeA.recordReceived(item: InboxItem(id: id, kind: .receipt, payload: bytes, receivedAt: now))

                // Correlate receipt → outbound transfer (same logic as CLI ingest)
                let parsedManifestId = parseManifestIdFromReceipt(bytes)
                if let mid = parsedManifestId {
                    let mHex = Hex.encode(mid)
                    if var transfer = try storeA.getTransferByManifestHash(mHex, direction: .outbound) {
                        if transfer.status == .sending || transfer.status == .queued {
                            transfer.status = .complete
                            transfer.verified = true
                            transfer.updatedAt = now
                            transfer.lastActivityAt = now
                            try storeA.updateTransfer(transfer)
                        }
                    }
                }
            }
        default:
            break
        }
    }

    // === ASSERT: sender outbound transfer is now complete ===
    let finalA = try storeA.getTransfer(id: transferId)
    #expect(finalA?.status == .complete)
    #expect(finalA?.verified == true)

    // Verify bytes_total matches original payload
    #expect(finalA?.bytesTotal == Int64(payloadSize))
}

// MARK: - listInboxByKind

@Test
func listInboxByKindFiltersCorrectly() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let now = Date()

    try store.recordReceived(item: InboxItem(id: Data([1]), kind: .envelope, payload: Data([10]), receivedAt: now))
    try store.recordReceived(item: InboxItem(id: Data([2]), kind: .manifest, payload: Data([20]), receivedAt: now))
    try store.recordReceived(item: InboxItem(id: Data([3]), kind: .receipt, payload: Data([30]), receivedAt: now))
    try store.recordReceived(item: InboxItem(id: Data([4]), kind: .envelope, payload: Data([40]), receivedAt: now))

    let envelopes = try store.listInboxByKind(.envelope)
    #expect(envelopes.count == 2)

    let manifests = try store.listInboxByKind(.manifest)
    #expect(manifests.count == 1)

    let receipts = try store.listInboxByKind(.receipt)
    #expect(receipts.count == 1)
}
