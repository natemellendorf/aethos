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

@Test
func simulatedTwoWayMessageExchangePreservesWayfarerChatPayloads() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let aliceStore = try AethosStore(path: dir.appendingPathComponent("alice.sqlite"))
    let bobStore = try AethosStore(path: dir.appendingPathComponent("bob.sqlite"))

    let duplex = SimDuplexLink()
    let alice = SimPeer(name: "alice", store: aliceStore, link: duplex.endpointA())
    let bob = SimPeer(name: "bob", store: bobStore, link: duplex.endpointB())
    let now = Date(timeIntervalSince1970: 1_735_689_600)

    let aliceAuthor = Data(repeating: 0xaa, count: 32)
    let bobAuthor = Data(repeating: 0xbb, count: 32)

    let aliceBody = try CanonicalCBOREncoder().encode(.map([
        .init(key: .text("text"), value: .text("hi from alice")),
        .init(key: .text("type"), value: .text("wayfarer.chat.v1")),
        .init(key: .text("created_at_unix_ms"), value: .unsigned(1_735_689_600_000)),
    ]))
    let bobBody = try CanonicalCBOREncoder().encode(.map([
        .init(key: .text("text"), value: .text("hi bob")),
        .init(key: .text("type"), value: .text("wayfarer.chat.v1")),
        .init(key: .text("created_at_unix_ms"), value: .unsigned(1_735_689_601_000)),
    ]))

    let aliceMessage = MessageV1(createdAtUnixMs: 1_735_689_600_000, authorWayfarerId: aliceAuthor, body: aliceBody)
    let bobMessage = MessageV1(createdAtUnixMs: 1_735_689_601_000, authorWayfarerId: bobAuthor, body: bobBody)

    let aliceCanonical = CanonicalEncoderV1.encode(aliceMessage)
    let bobCanonical = CanonicalEncoderV1.encode(bobMessage)

    try aliceStore.enqueue(item: OutboxItem(
        id: AethosIDs.messageId(canonicalBytes: aliceCanonical),
        kind: .message,
        payload: aliceCanonical,
        enqueuedAt: now
    ))
    try bobStore.enqueue(item: OutboxItem(
        id: AethosIDs.messageId(canonicalBytes: bobCanonical),
        kind: .message,
        payload: bobCanonical,
        enqueuedAt: now
    ))

    let budget = SessionBudget(maxBytes: 8 * 1024, maxItems: 8)
    _ = try SimSession.run(from: alice, to: bob, budget: budget, now: now)
    _ = try SimSession.run(from: bob, to: alice, budget: budget, now: now)

    let aliceRows = try aliceStore.listMessages(limit: 10)
    let bobRows = try bobStore.listMessages(limit: 10)

    #expect(aliceRows.count == 2)
    #expect(bobRows.count == 2)

    let aliceInbound = try #require(aliceRows.first(where: { $0.direction == .inbound }))
    let bobInbound = try #require(bobRows.first(where: { $0.direction == .inbound }))

    let aliceInboundMessage = try CanonicalEncoderV1.decodeMessage(canonical: aliceInbound.canonical)
    let bobInboundMessage = try CanonicalEncoderV1.decodeMessage(canonical: bobInbound.canonical)

    #expect(WayfarerPayloadCodec.chatText(body: aliceInboundMessage.body) == "hi bob")
    #expect(WayfarerPayloadCodec.chatText(body: bobInboundMessage.body) == "hi from alice")
}
