import Foundation
import Testing
@testable import AethosCore

@Test
func repeatedGossipRoundsConvergeAndRemainIdempotent() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let storeA = try AethosStore(path: dir.appendingPathComponent("storeA.sqlite"))
    let storeB = try AethosStore(path: dir.appendingPathComponent("storeB.sqlite"))

    let link = SimDuplexLink()
    let peerA = SimPeer(name: "A", store: storeA, link: link.endpointA())
    let peerB = SimPeer(name: "B", store: storeB, link: link.endpointB())

    let now = Date(timeIntervalSince1970: 1_000)
    let payload = Data((0..<(80 * 1024)).map { UInt8($0 % 251) })

    let chunks = Chunking.chunk(payload)
    for c in chunks {
        try storeA.putChunk(id: c.id, bytes: c.bytes, receivedAt: now)
    }

    let manifest = Chunking.buildManifest(for: payload)
    let manifestBytes = CanonicalEncoderV1.encode(manifest)
    let manifestId = AethosIDs.manifestId(from: manifest)

    let envelope = EnvelopeV1(
        toWayfarerId: Data(repeating: 0xBB, count: 32),
        manifestId: manifestId,
        body: Data("repeated-gossip.bin".utf8)
    )
    let envelopeBytes = CanonicalEncoderV1.encode(envelope)
    let envelopeId = AethosIDs.envelopeId(canonicalBytes: envelopeBytes)

    try storeA.enqueue(item: OutboxItem(id: manifestId, kind: .manifest, payload: manifestBytes, enqueuedAt: now))
    try storeA.enqueue(item: OutboxItem(id: envelopeId, kind: .envelope, payload: envelopeBytes, enqueuedAt: now))

    let budget = SessionBudget(maxBytes: 1_000_000, maxItems: 10_000)

    var completedAtRound: Int?
    for round in 0..<20 {
        let t = now.addingTimeInterval(TimeInterval(round))
        _ = try SimSession.run(from: peerA, to: peerB, budget: budget, now: t)
        _ = try SimSession.run(from: peerB, to: peerA, budget: budget, now: t)

        if completedAtRound == nil {
            var haveAll = true
            var chunksById: [Data: Data] = [:]
            for cId in manifest.chunkIds {
                guard let bytes = try storeB.getChunk(id: cId) else {
                    haveAll = false
                    break
                }
                chunksById[cId] = bytes
            }
            if haveAll {
                let rebuilt = try Chunking.reassemble(chunksById: chunksById, manifest: manifest)
                #expect(rebuilt == payload)
                completedAtRound = round
            }
        }
    }

    #expect(completedAtRound != nil)

    let chunksCountBefore = try storeB.__debugRowCount(table: "chunks")
    let inboxCountBefore = try storeB.__debugRowCount(table: "inbox")

    // More rounds should not introduce new chunk rows (chunks table is keyed by id).
    for round in 20..<30 {
        let t = now.addingTimeInterval(TimeInterval(round))
        _ = try SimSession.run(from: peerA, to: peerB, budget: budget, now: t)
        _ = try SimSession.run(from: peerB, to: peerA, budget: budget, now: t)
    }

    let chunksCountAfter = try storeB.__debugRowCount(table: "chunks")
    #expect(chunksCountAfter == chunksCountBefore)

    // Inbox may receive duplicates (ignored by primary key), but row count must not grow.
    let inboxCountAfter = try storeB.__debugRowCount(table: "inbox")
    #expect(inboxCountAfter == inboxCountBefore)
}

@Test
func threeNodeConvergesViaRelayOverMultipleRounds() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let storeA = try AethosStore(path: dir.appendingPathComponent("storeA.sqlite"))
    let storeR = try AethosStore(path: dir.appendingPathComponent("storeR.sqlite"))
    let storeB = try AethosStore(path: dir.appendingPathComponent("storeB.sqlite"))

    let linkAR = SimDuplexLink()
    let linkRB = SimDuplexLink()

    let peerA = SimPeer(name: "A", store: storeA, link: linkAR.endpointA())
    let peerR_fromA = SimPeer(name: "R_recv", store: storeR, link: linkAR.endpointB())
    let peerR_toB = SimPeer(name: "R_send", store: storeR, link: linkRB.endpointA())
    let peerB = SimPeer(name: "B", store: storeB, link: linkRB.endpointB())

    let now = Date(timeIntervalSince1970: 1_000)
    let payload = Data((0..<(120 * 1024)).map { UInt8($0 % 251) })

    let destB = Data(repeating: 0xBB, count: 32)
    let destBHex = destB.hexString

    let chunks = Chunking.chunk(payload)
    for c in chunks {
        try storeA.putChunk(id: c.id, bytes: c.bytes, receivedAt: now)
    }

    let manifest = Chunking.buildManifest(for: payload)
    let manifestBytes = CanonicalEncoderV1.encode(manifest)
    let manifestId = AethosIDs.manifestId(from: manifest)
    let manifestHashHex = manifestId.hexString

    let envelope = EnvelopeV1(toWayfarerId: destB, manifestId: manifestId, body: Data("via-relay.bin".utf8))
    let envelopeBytes = CanonicalEncoderV1.encode(envelope)
    let envelopeId = AethosIDs.envelopeId(canonicalBytes: envelopeBytes)

    try storeA.enqueue(item: OutboxItem(id: manifestId, kind: .manifest, payload: manifestBytes, enqueuedAt: now))
    try storeA.enqueue(item: OutboxItem(id: envelopeId, kind: .envelope, payload: envelopeBytes, enqueuedAt: now))

    // A -> R until R has all chunks.
    let fullBudget = SessionBudget(maxBytes: 1_000_000, maxItems: 10_000)
    for i in 0..<60 {
        _ = try SimSession.run(from: peerA, to: peerR_fromA, budget: fullBudget, now: now.addingTimeInterval(TimeInterval(i)))
        var allPresent = true
        for cId in manifest.chunkIds {
            if try storeR.getChunk(id: cId) == nil {
                allPresent = false
                break
            }
        }
        if allPresent { break }
    }

    // Mark relay custody in R.
    let transferR = Transfer(
        transferId: Transfer.newId(),
        direction: .inbound,
        peerFrom: "",
        peerTo: destBHex,
        createdAt: now,
        updatedAt: now,
        lastActivityAt: now,
        status: .receiving,
        bytesTotal: Int64(payload.count),
        bytesReceived: Int64(payload.count),
        partsTotal: Int32(chunks.count),
        partsReceived: Int32(chunks.count),
        manifestHash: manifestHashHex,
        custody: .relay
    )
    try storeR.createTransfer(transferR)

    // Replay by enqueueing manifest + envelope into R outbox (store-level idempotent).
    try storeR.enqueue(item: OutboxItem(id: manifestId, kind: .manifest, payload: manifestBytes, enqueuedAt: now))
    try storeR.enqueue(item: OutboxItem(id: envelopeId, kind: .envelope, payload: envelopeBytes, enqueuedAt: now))

    // R -> B over multiple rounds.
    var delivered = false
    for i in 0..<80 {
        let t = now.addingTimeInterval(TimeInterval(200 + i))
        _ = try SimSession.run(from: peerR_toB, to: peerB, budget: fullBudget, now: t)

        var chunksById: [Data: Data] = [:]
        var haveAll = true
        for cId in manifest.chunkIds {
            guard let bytes = try storeB.getChunk(id: cId) else {
                haveAll = false
                break
            }
            chunksById[cId] = bytes
        }
        if haveAll {
            let rebuilt = try Chunking.reassemble(chunksById: chunksById, manifest: manifest)
            #expect(rebuilt == payload)
            delivered = true
            break
        }
    }

    #expect(delivered)
}
