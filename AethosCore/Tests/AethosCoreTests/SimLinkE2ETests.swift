import Foundation
import Testing
@testable import AethosCore

@Test
func simulatedLinkEventuallyDeliversPayload() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let senderDB = dir.appendingPathComponent("sender.sqlite")
    let receiverDB = dir.appendingPathComponent("receiver.sqlite")

    let senderStore = try AethosStore(path: senderDB)
    let receiverStore = try AethosStore(path: receiverDB)

    let duplex = SimDuplexLink()
    let sender = SimPeer(name: "sender", store: senderStore, link: duplex.endpointA())
    let receiver = SimPeer(name: "receiver", store: receiverStore, link: duplex.endpointB())

    // 200KB deterministic payload.
    let payload = Data((0..<(200 * 1024)).map { UInt8($0 % 251) })
    let now = Date(timeIntervalSince1970: 1_000)

    // Sender seeds chunk bytes + manifest + envelope into outbox.
    let chunks = Chunking.chunk(payload)
    for c in chunks {
        try senderStore.putChunk(id: c.id, bytes: c.bytes, receivedAt: now)
    }

    let manifest = Chunking.buildManifest(for: payload)
    let manifestBytes = CanonicalEncoderV1.encode(manifest)
    let manifestId = AethosIDs.manifestId(from: manifest)

    let envelope = EnvelopeV1(
        toWayfarerId: Data(repeating: 0xAA, count: 32),
        manifestId: manifestId,
        body: Data("payload".utf8)
    )
    let envelopeBytes = CanonicalEncoderV1.encode(envelope)

    try senderStore.enqueue(item: OutboxItem(id: manifestId, kind: .manifest, payload: manifestBytes, enqueuedAt: now))
    try senderStore.enqueue(item: OutboxItem(id: AethosIDs.envelopeId(canonicalBytes: envelopeBytes), kind: .envelope, payload: envelopeBytes, enqueuedAt: now))

    // Small budget to force multipart chunk transfer.
    let budget = SessionBudget(maxBytes: 6 * 1024, maxItems: 8)

    var delivered = false
    for i in 0..<50 {
        let sessionNow = now.addingTimeInterval(TimeInterval(i))
        _ = try SimSession.run(from: sender, to: receiver, budget: budget, now: sessionNow)

        // Try to reassemble if receiver has manifest and all chunks.
        // Receiver records manifest/envelope into inbox; for E2E we use the sender's manifest
        // and validate the receiver has all referenced chunks.
        var allPresent = true
        var chunksMap: [Data: Data] = [:]
        chunksMap.reserveCapacity(manifest.chunkIds.count)
        for id in manifest.chunkIds {
            if let bytes = try receiverStore.getChunk(id: id) {
                chunksMap[id] = bytes
            } else {
                allPresent = false
                break
            }
        }
        if allPresent {
            let rebuilt = try Chunking.reassemble(chunksById: chunksMap, manifest: manifest)
            #expect(rebuilt == payload)
            delivered = true
            break
        }

    }

    #expect(delivered)

    // Duplicates should not cause unbounded growth.
    #expect(try receiverStore.__debugRowCount(table: "chunks") == manifest.chunkIds.count)
}
