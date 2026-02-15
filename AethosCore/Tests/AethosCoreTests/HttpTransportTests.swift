import Foundation
import Testing
@testable import AethosCore

@Test
func httpFrameRoundTrip() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    try fm.createDirectory(at: root, withIntermediateDirectories: true)

    let inbox = root.appendingPathComponent("inbox", isDirectory: true)
    let outbox = root.appendingPathComponent("outbox", isDirectory: true)
    let archive = root.appendingPathComponent("archive", isDirectory: true)

    let serverId = String(repeating: "aa", count: 32)
    let running = try startServer(inbox: inbox, outbox: outbox, archive: archive, wayfarerHex: serverId)
    defer { try? running.server.stop() }

    let base = URL(string: "http://127.0.0.1:\(running.port)")!
    let link = try HttpLink(baseURL: base, localWayfarerIdHex: String(repeating: "bb", count: 32), expectedRemoteWayfarerIdHex: serverId)

    let frameA = Frame(type: CargoCodec.FrameType.inventory.rawValue, id: Data(repeating: 0x01, count: 32), partIndex: 0, partCount: 1, payload: Data("hello".utf8))
    try link.send(frameA)

    // Server should have persisted bytes into inbox.
    let inboxFiles = try waitForFileCount(in: inbox, count: 1)
    let storedBytes = try Data(contentsOf: inboxFiles[0])
    #expect((try? Frame.decode(storedBytes)) == frameA)

    // Seed server outbox and receive it via HTTP.
    let frameB = Frame(type: CargoCodec.FrameType.receipt.rawValue, id: Data(repeating: 0x02, count: 32), partIndex: 0, partCount: 1, payload: Data([0x9]))
    let outFile = outbox.appendingPathComponent("0001.bin")
    try frameB.encode().write(to: outFile, options: [.atomic])

    let received = try link.receive()
    #expect(received == frameB)

    let archived = try fm.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil)
    #expect(archived.contains { $0.lastPathComponent == "0001.bin" })
}

@Test
func httpRejectsInvalidFrame() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    try fm.createDirectory(at: root, withIntermediateDirectories: true)

    let inbox = root.appendingPathComponent("inbox", isDirectory: true)
    let outbox = root.appendingPathComponent("outbox", isDirectory: true)
    let archive = root.appendingPathComponent("archive", isDirectory: true)

    let running = try startServer(inbox: inbox, outbox: outbox, archive: archive, wayfarerHex: String(repeating: "aa", count: 32))
    defer { try? running.server.stop() }

    let url = URL(string: "http://127.0.0.1:\(running.port)/frames")!
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.httpBody = Data("not-a-frame".utf8)
    req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    req.setValue("\(req.httpBody?.count ?? 0)", forHTTPHeaderField: "Content-Length")

    let status = try httpStatus(req)
    #expect(status == 400)
}

@Test
func httpWorksWithTLSDisabled() throws {
    // Intentionally uses http:// (no TLS).
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    try fm.createDirectory(at: root, withIntermediateDirectories: true)

    let inbox = root.appendingPathComponent("inbox", isDirectory: true)
    let outbox = root.appendingPathComponent("outbox", isDirectory: true)
    let archive = root.appendingPathComponent("archive", isDirectory: true)

    let running = try startServer(inbox: inbox, outbox: outbox, archive: archive, wayfarerHex: String(repeating: "aa", count: 32))
    defer { try? running.server.stop() }

    let base = URL(string: "http://127.0.0.1:\(running.port)")!
    let link = try HttpLink(baseURL: base)
    let frame = Frame(type: CargoCodec.FrameType.inventory.rawValue, id: Data(repeating: 0x01, count: 32), partIndex: 0, partCount: 1, payload: Data([0x1]))
    try link.send(frame)
    _ = try waitForFileCount(in: inbox, count: 1)
}

@Test
func httpExchangeBetweenTwoPeers() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    try fm.createDirectory(at: root, withIntermediateDirectories: true)

    let peerA = root.appendingPathComponent("A", isDirectory: true)
    let peerB = root.appendingPathComponent("B", isDirectory: true)
    try fm.createDirectory(at: peerA, withIntermediateDirectories: true)
    try fm.createDirectory(at: peerB, withIntermediateDirectories: true)

    let aInbox = peerA.appendingPathComponent("inbox", isDirectory: true)
    let aOutbox = peerA.appendingPathComponent("outbox", isDirectory: true)
    let aArchive = peerA.appendingPathComponent("archive", isDirectory: true)
    let bInbox = peerB.appendingPathComponent("inbox", isDirectory: true)
    let bOutbox = peerB.appendingPathComponent("outbox", isDirectory: true)
    let bArchive = peerB.appendingPathComponent("archive", isDirectory: true)

    let aId = String(repeating: "aa", count: 32)
    let bId = String(repeating: "bb", count: 32)

    let runningA = try startServer(inbox: aInbox, outbox: aOutbox, archive: aArchive, wayfarerHex: aId)
    let runningB = try startServer(inbox: bInbox, outbox: bOutbox, archive: bArchive, wayfarerHex: bId)
    defer {
        try? runningA.server.stop()
        try? runningB.server.stop()
    }

    let storeA = try AethosStore(path: peerA.appendingPathComponent("store.sqlite"))
    let storeB = try AethosStore(path: peerB.appendingPathComponent("store.sqlite"))

    // Seed A with a payload.
    let payload = Data((0..<(200 * 1024)).map { UInt8($0 % 251) })
    let chunks = Chunking.chunk(payload)
    let now = Date(timeIntervalSince1970: 1_000)
    for c in chunks {
        try storeA.putChunk(id: c.id, bytes: c.bytes, receivedAt: now)
    }
    let manifest = Chunking.buildManifest(for: payload)
    let manifestBytes = CanonicalEncoderV1.encode(manifest)
    let manifestId = AethosIDs.manifestId(from: manifest)
    let envelope = EnvelopeV1(toWayfarerId: Data(repeating: 0x99, count: 32), manifestId: manifestId, body: Data("x".utf8))
    let envelopeBytes = CanonicalEncoderV1.encode(envelope)

    try storeA.enqueue(item: OutboxItem(id: manifestId, kind: .manifest, payload: manifestBytes, enqueuedAt: now))
    try storeA.enqueue(item: OutboxItem(id: AethosIDs.envelopeId(canonicalBytes: envelopeBytes), kind: .envelope, payload: envelopeBytes, enqueuedAt: now))

    // Pump A into A server outbox files.
    try pumpStoreToOutbox(store: storeA, outboxDir: aOutbox, maxBytes: 64 * 1024)

    // B pulls frames from A via GET and ingests.
    let linkBtoA = try HttpLink(baseURL: URL(string: "http://127.0.0.1:\(runningA.port)")!, localWayfarerIdHex: bId, expectedRemoteWayfarerIdHex: aId)
    try ingestAll(link: linkBtoA, store: storeB)

    // Keep pulling/pumping until B can reassemble.
    var delivered = false
    for _ in 0..<50 {
        // Pump more from A
        try pumpStoreToOutbox(store: storeA, outboxDir: aOutbox, maxBytes: 64 * 1024)
        try ingestAll(link: linkBtoA, store: storeB)

        if let rebuilt = try tryReassemble(store: storeB, manifest: manifest) {
            #expect(rebuilt == payload)
            delivered = true
            break
        }
    }
    #expect(delivered)
}

@Test
func httpDoesNotBreakInventoryFlow() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    try fm.createDirectory(at: root, withIntermediateDirectories: true)

    let inbox = root.appendingPathComponent("inbox", isDirectory: true)
    let outbox = root.appendingPathComponent("outbox", isDirectory: true)
    let archive = root.appendingPathComponent("archive", isDirectory: true)

    let running = try startServer(inbox: inbox, outbox: outbox, archive: archive, wayfarerHex: String(repeating: "aa", count: 32))
    defer { try? running.server.stop() }

    let store = try AethosStore(path: root.appendingPathComponent("store.sqlite"))

    // Seed an InventoryV1 frame into server outbox and ensure it is decoded/stored.
    let inv = InventoryV1(manifests: [String(repeating: "11", count: 32)], generatedAtUnixMs: 1)
    let invBytes = CanonicalEncoderV1.encode(inv)
    let invFrame = Frame(type: CargoCodec.FrameType.inventory.rawValue, id: AethosIDs.sha256(invBytes), partIndex: 0, partCount: 1, payload: invBytes)
    try invFrame.encode().write(to: outbox.appendingPathComponent("000-inv.bin"), options: [.atomic])

    let link = try HttpLink(baseURL: URL(string: "http://127.0.0.1:\(running.port)")!)
    try ingestAll(link: link, store: store)

    let inboxItems = try store.listInboxByKind(.inventory)
    #expect(inboxItems.count >= 1)
    #expect((try? CanonicalEncoderV1.decodeInventory(canonical: inboxItems[0].payload)) != nil)
}

// MARK: - Test helpers

private struct RunningServer {
    let server: HttpFrameServer
    let port: UInt16
}

private func startServer(inbox: URL, outbox: URL, archive: URL, wayfarerHex: String) throws -> RunningServer {
    let fm = FileManager.default
    try fm.createDirectory(at: inbox, withIntermediateDirectories: true)
    try fm.createDirectory(at: outbox, withIntermediateDirectories: true)
    try fm.createDirectory(at: archive, withIntermediateDirectories: true)

    for _ in 0..<50 {
        let port = UInt16.random(in: 20_000...50_000)
        do {
            let s = try HttpFrameServer(
                bindHost: "127.0.0.1",
                port: port,
                inboxDir: inbox,
                outboxDir: outbox,
                archiveDir: archive,
                localWayfarerIdHex: wayfarerHex
            )
            try s.start()
            // Give listener a beat.
            Thread.sleep(forTimeInterval: 0.05)
            return RunningServer(server: s, port: port)
        } catch {
            continue
        }
    }
    throw NSError(domain: "HttpTransportTests", code: 1)
}

private func waitForFileCount(in dir: URL, count: Int) throws -> [URL] {
    let fm = FileManager.default
    for _ in 0..<100 {
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        if files.count >= count {
            return files
        }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return (try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))
}

private func httpStatus(_ req: URLRequest) throws -> Int {
    let sema = DispatchSemaphore(value: 0)

    final class Box: @unchecked Sendable {
        var status: Int = -1
    }
    let box = Box()

    URLSession.shared.dataTask(with: req) { _, resp, _ in
        box.status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        sema.signal()
    }.resume()
    _ = sema.wait(timeout: .now() + 5)
    return box.status
}

private func pumpStoreToOutbox(store: AethosStore, outboxDir: URL, maxBytes: Int) throws {
    let router = Router(store: store)
    let plan = try router.planNextSession(budget: SessionBudget(maxBytes: maxBytes, maxItems: 256), now: Date())
    var remaining = maxBytes

    for item in plan {
        let frames = try CargoCodec.encode(item, maxFramePayloadBytes: 1024)
        for f in frames {
            if f.sizeBytes > remaining { return }
            let name = String(format: "%012d-%@.bin", Int(Date().timeIntervalSince1970 * 1000), UUID().uuidString)
            let url = outboxDir.appendingPathComponent(name, isDirectory: false)
            try f.encode().write(to: url, options: [.atomic])
            remaining -= f.sizeBytes
        }
    }
}

private func ingestAll(link: HttpLink, store: AethosStore) throws {
    var partials: [Data: (UInt16, [UInt16: Data])] = [:]

    while let frame = try link.receive() {
        let frag = try CargoCodec.decode(frame)
        switch frag {
        case let .metadata(type, id, bytes):
            switch CargoCodec.FrameType(rawValue: type) {
            case .receipt:
                try store.recordReceived(item: InboxItem(id: id, kind: .receipt, payload: bytes, receivedAt: Date()))
            case .envelope:
                try store.recordReceived(item: InboxItem(id: id, kind: .envelope, payload: bytes, receivedAt: Date()))
            case .manifest:
                try store.recordReceived(item: InboxItem(id: id, kind: .manifest, payload: bytes, receivedAt: Date()))
            case .inventory:
                try store.recordReceived(item: InboxItem(id: id, kind: .inventory, payload: bytes, receivedAt: Date()))
            case .inventoryRequest:
                try store.recordReceived(item: InboxItem(id: id, kind: .inventoryRequest, payload: bytes, receivedAt: Date()))
            case .chunk, .none:
                break
            }
        case let .chunkPart(id, partIndex, partCount, bytes):
            var entry = partials[id] ?? (partCount, [:])
            if entry.0 == partCount {
                entry.1[partIndex] = bytes
            }
            partials[id] = entry
            if entry.1.count == Int(partCount) {
                var full = Data()
                for i in 0..<partCount {
                    guard let p = entry.1[i] else { return }
                    full.append(p)
                }
                try store.putChunk(id: id, bytes: full, receivedAt: Date())
                partials[id] = nil
            }
        }
    }
}

private func tryReassemble(store: AethosStore, manifest: ManifestV1) throws -> Data? {
    var map: [Data: Data] = [:]
    for id in manifest.chunkIds {
        guard let bytes = try store.getChunk(id: id) else { return nil }
        map[id] = bytes
    }
    return try Chunking.reassemble(chunksById: map, manifest: manifest)
}
