import AethosCore
import Foundation

enum CLIError: Swift.Error {
    case usage(String)
}

struct CLI {
    let args: [String]

    func run() throws {
        var argv = args
        _ = argv.first
        argv = Array(argv.dropFirst())

        guard let command = argv.first else {
            throw CLIError.usage(Self.usage)
        }
        argv = Array(argv.dropFirst())

        let (home, rest, jsonOutput) = try parseGlobalArgs(from: argv)
        switch command {
        case "init":
            try cmdInit(home: home, args: rest)
        case "status":
            try cmdStatus(home: home, args: rest, json: jsonOutput)
        case "send":
            try cmdSend(home: home, args: rest)
        case "ingest":
            try cmdIngest(home: home, args: rest)
        case "pump":
            try cmdPump(home: home, args: rest)
        case "transfers":
            try cmdTransfers(home: home, args: rest, json: jsonOutput)
        case "help", "--help", "-h":
            print(Self.usage)
        default:
            throw CLIError.usage("Unknown command: \(command)\n\n\(Self.usage)")
        }
    }

    private func parseGlobalArgs(from args: [String]) throws -> (PeerHome, [String], Bool) {
        var rest: [String] = []
        var i = 0
        var homeURL: URL? = nil
        var jsonOutput = false

        while i < args.count {
            let a = args[i]
            if a == "--home" {
                guard i + 1 < args.count else { throw CLIError.usage("--home requires a path") }
                homeURL = URL(fileURLWithPath: args[i + 1])
                i += 2
                continue
            }
            if a == "--json" {
                jsonOutput = true
                i += 1
                continue
            }
            rest.append(a)
            i += 1
        }

        return (PeerHome(root: homeURL ?? PeerHome.defaultRootURL()), rest, jsonOutput)
    }

    // MARK: - init

    private func cmdInit(home: PeerHome, args: [String]) throws {
        guard args.isEmpty else {
            throw CLIError.usage("init takes no positional args")
        }

        try home.createDirectories()
        _ = try AethosStore(path: home.storeSQLitePath)

        let identityStore = DefaultIdentityStore(directory: home.identityDir)
        let identityManager = IdentityManager(store: identityStore)
        let identity = try identityManager.loadOrCreate()

        print("Initialized peer home:\n  \(home.root.path)")
        print("Store:\n  \(home.storeSQLitePath.path)")
        print("Identity:\n  wayfarerId=\(identity.wayfarerId.hexString)\n  shortId=\(identity.shortId)")
        print("Transport dirs:\n  inbox=\(home.transportInboxDir.path)\n  outbox=\(home.transportOutboxDir.path)\n  archive=\(home.transportArchiveDir.path)")
    }

    // MARK: - status

    private func cmdStatus(home: PeerHome, args: [String], json: Bool) throws {
        guard args.isEmpty else {
            throw CLIError.usage("status takes no positional args")
        }

        let fm = FileManager.default
        let storeExists = fm.fileExists(atPath: home.storeSQLitePath.path)

        var wayfarerIdHex: String? = nil
        var shortId: String? = nil
        do {
            let identityStore = DefaultIdentityStore(directory: home.identityDir)
            let identityManager = IdentityManager(store: identityStore)
            let identity = try identityManager.loadOrCreate()
            wayfarerIdHex = identity.wayfarerId.hexString
            shortId = identity.shortId
        } catch {}

        if json {
            var obj: [String: Any] = [
                "peer": [
                    "home": home.root.path,
                    "wayfarerId": wayfarerIdHex ?? "",
                    "shortId": shortId ?? "",
                ],
                "store": [
                    "path": home.storeSQLitePath.path,
                    "exists": storeExists,
                ],
                "transport": [
                    "inbox": home.transportInboxDir.path,
                    "outbox": home.transportOutboxDir.path,
                    "archive": home.transportArchiveDir.path,
                ],
            ]

            if storeExists {
                let store = try AethosStore(path: home.storeSQLitePath)
                let transfers = try store.listTransfers()
                obj["transfers_summary"] = [
                    "total": transfers.count,
                    "queued": transfers.filter { $0.status == .queued }.count,
                    "sending": transfers.filter { $0.status == .sending }.count,
                    "receiving": transfers.filter { $0.status == .receiving }.count,
                    "complete": transfers.filter { $0.status == .complete }.count,
                    "failed": transfers.filter { $0.status == .failed }.count,
                ]
            }

            print(jsonString(obj))
        } else {
            print("Peer home:\n  \(home.root.path)")
            print("Store:\n  \(home.storeSQLitePath.path) (exists: \(storeExists ? "yes" : "no"))")
            print("Transport dirs:\n  inbox=\(home.transportInboxDir.path)\n  outbox=\(home.transportOutboxDir.path)\n  archive=\(home.transportArchiveDir.path)")
            if let wid = wayfarerIdHex, let sid = shortId {
                print("Identity:\n  wayfarerId=\(wid)\n  shortId=\(sid)")
            } else {
                print("Identity:\n  not initialized (run: aethos init)")
            }
        }
    }

    // MARK: - send

    private func cmdSend(home: PeerHome, args: [String]) throws {
        let parsed = try parseKeyValues(args)

        guard let file = parsed["--file"], !file.isEmpty else { throw CLIError.usage("send requires --file <path>") }
        guard let toHex = parsed["--to"], !toHex.isEmpty else { throw CLIError.usage("send requires --to <wayfarerId-hex>") }
        guard let toWayfarerId = Hex.decode(toHex), toWayfarerId.count == 32 else {
            throw CLIError.usage("--to must be 32-byte hex")
        }

        let fileURL = URL(fileURLWithPath: file)
        let data = try Data(contentsOf: fileURL)

        try home.createDirectories()
        let store = try AethosStore(path: home.storeSQLitePath)
        let now = Date()

        let chunks = Chunking.chunk(data)
        for c in chunks {
            try store.putChunk(id: c.id, bytes: c.bytes, receivedAt: now)
        }

        let manifest = Chunking.buildManifest(for: data)
        let manifestBytes = CanonicalEncoderV1.encode(manifest)
        let manifestId = AethosIDs.manifestId(from: manifest)

        let envelope = EnvelopeV1(
            toWayfarerId: toWayfarerId,
            manifestId: manifestId,
            body: Data((fileURL.lastPathComponent).utf8)
        )
        let envelopeBytes = CanonicalEncoderV1.encode(envelope)
        let envelopeId = AethosIDs.envelopeId(from: envelope)

        try store.enqueue(item: OutboxItem(id: manifestId, kind: .manifest, payload: manifestBytes, enqueuedAt: now))
        try store.enqueue(item: OutboxItem(id: envelopeId, kind: .envelope, payload: envelopeBytes, enqueuedAt: now))

        // Create outbound transfer
        let identityStore = DefaultIdentityStore(directory: home.identityDir)
        let identityManager = IdentityManager(store: identityStore)
        let identity = try identityManager.loadOrCreate()

        let transferId = Transfer.newId()
        let transfer = Transfer(
            transferId: transferId,
            direction: .outbound,
            peerFrom: identity.wayfarerId.hexString,
            peerTo: toHex,
            createdAt: now,
            updatedAt: now,
            lastActivityAt: now,
            status: .queued,
            originalFilename: fileURL.lastPathComponent,
            bytesTotal: Int64(data.count),
            bytesSent: 0,
            bytesReceived: 0,
            partsTotal: Int32(chunks.count),
            partsSent: 0,
            partsReceived: 0,
            manifestHash: manifestId.hexString,
            payloadHash: AethosIDs.sha256(data).hexString,
            verified: false,
            lastError: nil
        )
        try store.createTransfer(transfer)

        print("Queued send")
        print("  file=\(fileURL.path)")
        print("  bytes=\(data.count)")
        print("  chunks=\(chunks.count)")
        print("  manifestId=\(manifestId.hexString)")
        print("  envelopeId=\(envelopeId.hexString)")
        print("  transferId=\(transferId)")
    }

    // MARK: - ingest

    private func cmdIngest(home: PeerHome, args: [String]) throws {
        let parsed = try parseKeyValues(args)
        let ingestMax = Int(parsed["--max"] ?? "100")
        guard let ingestMax, ingestMax > 0 else { throw CLIError.usage("--max must be > 0") }

        try home.createDirectories()
        let store = try AethosStore(path: home.storeSQLitePath)
        let link = try FileDropLink(inboxDir: home.transportInboxDir, outboxDir: home.transportOutboxDir, archiveDir: home.transportArchiveDir)

        // Load identity for inbound transfer creation
        let identityStore = DefaultIdentityStore(directory: home.identityDir)
        let identityManager = IdentityManager(store: identityStore)
        let localIdentity = try identityManager.loadOrCreate()
        let localWayfarerHex = localIdentity.wayfarerId.hexString

        let fm = FileManager.default
        let beforeBad = countBadFiles(in: home.transportArchiveDir, fileManager: fm)

        // Build chunk→manifestHash mapping from cached manifests
        var chunkToManifestHash = buildChunkToManifestMap(home: home, fm: fm)

        var receivedFrames = 0
        var storedItems = 0

        for _ in 0..<ingestMax {
            guard let frame = try link.receive() else { break }
            receivedFrames += 1

            let fragment = try CargoCodec.decode(frame)
            switch fragment {
            case let .metadata(type, id, bytes):
                switch CargoCodec.FrameType(rawValue: type) {
                case .receipt:
                    try store.recordReceived(item: InboxItem(id: id, kind: .receipt, payload: bytes, receivedAt: Date()))
                    storedItems += 1

                    // Correlate receipt to outbound transfer on the sender side.
                    // ReceiptV1 contains manifestId — use it to find the matching outbound transfer.
                    if let receiptInfo = try? parseReceiptCanonical(bytes) {
                        let manifestHashHex = Hex.encode(receiptInfo.manifestId)
                        if var transfer = try store.getTransferByManifestHash(manifestHashHex, direction: .outbound) {
                            if transfer.status == .sending || transfer.status == .queued {
                                transfer.status = .complete
                                transfer.verified = true
                                transfer.updatedAt = Date()
                                transfer.lastActivityAt = Date()
                                try store.updateTransfer(transfer)
                            }
                        }
                    }
                case .envelope:
                    try store.recordReceived(item: InboxItem(id: id, kind: .envelope, payload: bytes, receivedAt: Date()))
                    storedItems += 1

                    // Update inbound transfer with envelope metadata (filename)
                    if let envelopeInfo = try? parseEnvelopeCanonical(bytes) {
                        let manifestHashHex = Hex.encode(envelopeInfo.manifestId)
                        if var transfer = try store.getTransferByManifestHash(manifestHashHex, direction: .inbound) {
                            if transfer.originalFilename == nil,
                               let filename = String(data: envelopeInfo.body, encoding: .utf8), !filename.isEmpty {
                                transfer.originalFilename = filename
                                transfer.updatedAt = Date()
                                try store.updateTransfer(transfer)
                            }
                        }
                    }
                case .manifest:
                    try store.recordReceived(item: InboxItem(id: id, kind: .manifest, payload: bytes, receivedAt: Date()))
                    storedItems += 1

                    // Cache manifest canonical bytes for later reassembly.
                    let manifestPath = home.transportManifestCacheDir.appendingPathComponent("\(Hex.encode(id)).bin")
                    if !fm.fileExists(atPath: manifestPath.path) {
                        try bytes.write(to: manifestPath, options: [.atomic])
                    }

                    // Create inbound transfer if not already present
                    let manifestHashHex = Hex.encode(id)
                    if try store.getTransferByManifestHash(manifestHashHex, direction: .inbound) == nil {
                        let (totalSize, chunkIds) = try parseManifestCanonical(bytes)
                        let transfer = Transfer(
                            transferId: Transfer.newId(),
                            direction: .inbound,
                            peerFrom: "",
                            peerTo: localWayfarerHex,
                            createdAt: Date(),
                            updatedAt: Date(),
                            lastActivityAt: Date(),
                            status: .receiving,
                            bytesTotal: Int64(totalSize),
                            partsTotal: Int32(chunkIds.count),
                            manifestHash: manifestHashHex
                        )
                        try store.createTransfer(transfer)

                        // Update chunk→manifest mapping
                        for cId in chunkIds {
                            chunkToManifestHash[cId] = manifestHashHex
                        }
                    }
                case .chunk, .none:
                    break
                }

            case let .chunkPart(id, partIndex, partCount, bytes):
                let chunkHex = Hex.encode(id)
                let chunkDir = home.transportPartsDir.appendingPathComponent("chunk-\(chunkHex)", isDirectory: true)
                try fm.createDirectory(at: chunkDir, withIntermediateDirectories: true)
                let partURL = chunkDir.appendingPathComponent("part-\(partIndex)-of-\(partCount).bin")

                if !fm.fileExists(atPath: partURL.path) {
                    try bytes.write(to: partURL, options: [.atomic])
                }

                // Scan disk for all existing parts (spans across ingest invocations).
                let existingFiles = (try? fm.contentsOfDirectory(at: chunkDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                var diskParts: [UInt16: URL] = [:]
                for f in existingFiles {
                    let name = f.deletingPathExtension().lastPathComponent
                    let comps = name.split(separator: "-")
                    if comps.count == 4, comps[0] == "part", comps[2] == "of",
                       let idx = UInt16(comps[1]), let total = UInt16(comps[3]),
                       total == partCount {
                        diskParts[idx] = f
                    }
                }

                if diskParts.count == Int(partCount) {
                    var full = Data()
                    full.reserveCapacity(diskParts.values.reduce(0) { $0 + ((try? Data(contentsOf: $1).count) ?? 0) })
                    for i in 0..<partCount {
                        guard let url = diskParts[i], let partData = try? Data(contentsOf: url) else {
                            full = Data()
                            break
                        }
                        full.append(partData)
                    }

                    if !full.isEmpty {
                        try store.putChunk(id: id, bytes: full, receivedAt: Date())
                        storedItems += 1

                        // Update inbound transfer progress
                        if let manifestHashHex = chunkToManifestHash[id] {
                            if var transfer = try store.getTransferByManifestHash(manifestHashHex, direction: .inbound) {
                                transfer.partsReceived += 1
                                transfer.bytesReceived += Int64(full.count)
                                transfer.lastActivityAt = Date()
                                transfer.updatedAt = Date()
                                try store.updateTransfer(transfer)
                            }
                        }

                        // Cleanup part files after successful assembly.
                        try? fm.removeItem(at: chunkDir)
                    }
                }
            }

            // After each frame, try to reassemble any cached manifests that are now satisfiable.
            storedItems += try tryReassembleCachedManifests(home: home, store: store)
        }

        let afterBad = countBadFiles(in: home.transportArchiveDir, fileManager: fm)
        let badDelta = Swift.max(0, afterBad - beforeBad)

        print("ingest")
        print("  frames=\(receivedFrames)")
        print("  stored=\(storedItems)")
        print("  archivedBad=\(badDelta)")
    }

    // MARK: - pump

    private func cmdPump(home: PeerHome, args: [String]) throws {
        let parsed = try parseKeyValues(args)

        let maxBytes = Int(parsed["--max-bytes"] ?? "6144")
        let maxItems = Int(parsed["--max-items"] ?? "64")
        guard let maxBytes, maxBytes > 0 else { throw CLIError.usage("--max-bytes must be > 0") }
        guard let maxItems, maxItems > 0 else { throw CLIError.usage("--max-items must be > 0") }

        try home.createDirectories()
        let store = try AethosStore(path: home.storeSQLitePath)
        let router = Router(store: store)
        let link = try FileDropLink(inboxDir: home.transportInboxDir, outboxDir: home.transportOutboxDir, archiveDir: home.transportArchiveDir)

        // Use an inflated planning budget so the router includes all chunks in the plan.
        // The pump's actual send loop enforces the real budget per frame.
        let planBudget = SessionBudget(maxBytes: maxBytes * 10, maxItems: maxItems * 10)
        let plan = try router.planNextSession(budget: planBudget, now: Date())

        var cursor = try loadSendCursors(from: home.transportCursorPath)

        // Build chunk→manifestHash mapping from plan manifests
        var chunkToManifestHash: [String: String] = [:]
        var manifestChunkHexes: [String: [String]] = [:]
        for item in plan {
            if case let .manifest(bytes) = item {
                let mId = AethosIDs.manifestId(canonicalBytes: bytes)
                let mHex = Hex.encode(mId)
                let (_, chunkIds) = try parseManifestCanonical(bytes)
                let hexes = chunkIds.map { Hex.encode($0) }
                manifestChunkHexes[mHex] = hexes
                for cHex in hexes {
                    chunkToManifestHash[cHex] = mHex
                }
            }
        }

        // Track per-manifest bytes sent this session
        var manifestBytesDelta: [String: Int] = [:]

        var sentFrames = 0
        var sentBytes = 0

        let maxFramePayloadBytes = 1024
        var remainingBytes = maxBytes
        var remainingItems = maxItems

        for item in plan {
            if remainingBytes <= 0 || remainingItems <= 0 { break }

            let frames = try CargoCodec.encode(item, maxFramePayloadBytes: maxFramePayloadBytes)
            if frames.isEmpty { continue }

            switch item {
            case let .receipt(bytes):
                let frame = frames[0]
                if frame.sizeBytes > remainingBytes { continue }
                try link.send(frame)
                sentFrames += 1
                sentBytes += frame.sizeBytes
                remainingBytes -= frame.sizeBytes
                remainingItems -= 1
                try store.markDelivered(itemId: AethosIDs.receiptId(canonicalBytes: bytes))

            case let .envelope(bytes):
                let frame = frames[0]
                if frame.sizeBytes > remainingBytes { continue }
                try link.send(frame)
                sentFrames += 1
                sentBytes += frame.sizeBytes
                remainingBytes -= frame.sizeBytes
                remainingItems -= 1
                try store.markDelivered(itemId: AethosIDs.envelopeId(canonicalBytes: bytes))

            case .manifest:
                let frame = frames[0]
                if frame.sizeBytes > remainingBytes { continue }
                try link.send(frame)
                sentFrames += 1
                sentBytes += frame.sizeBytes
                remainingBytes -= frame.sizeBytes
                remainingItems -= 1

            case let .chunk(id, _):
                let chunkHex = Hex.encode(id)
                let idx = Int(cursor[chunkHex] ?? 0) % frames.count
                let frame = frames[idx]
                if frame.sizeBytes > remainingBytes { continue }
                try link.send(frame)
                sentFrames += 1
                sentBytes += frame.sizeBytes
                remainingBytes -= frame.sizeBytes
                remainingItems -= 1
                cursor[chunkHex] = UInt16((idx + 1) % frames.count)

                // Track bytes sent per manifest
                if let mHex = chunkToManifestHash[chunkHex] {
                    manifestBytesDelta[mHex, default: 0] += frame.sizeBytes
                }
            }
        }

        try saveSendCursors(cursor, to: home.transportCursorPath)

        // Update outbound transfer progress
        let affectedManifests = Set(manifestBytesDelta.keys)
        for mHex in affectedManifests {
            if var transfer = try store.getTransferByManifestHash(mHex, direction: .outbound) {
                transfer.bytesSent += Int64(manifestBytesDelta[mHex] ?? 0)

                // Count chunks with any send progress via cursor
                if let allChunkHexes = manifestChunkHexes[mHex] {
                    var partsWithProgress: Int32 = 0
                    for cHex in allChunkHexes {
                        if (cursor[cHex] ?? 0) > 0 {
                            partsWithProgress += 1
                        }
                    }
                    transfer.partsSent = partsWithProgress
                }

                if transfer.status == .queued {
                    transfer.status = .sending
                }
                transfer.updatedAt = Date()
                transfer.lastActivityAt = Date()
                try store.updateTransfer(transfer)
            }
        }

        print("pump")
        print("  plannedItems=\(plan.count)")
        print("  framesSent=\(sentFrames)")
        print("  bytesSent=\(sentBytes)")
    }

    // MARK: - transfers

    private func cmdTransfers(home: PeerHome, args: [String], json: Bool) throws {
        guard let sub = args.first else {
            throw CLIError.usage("transfers requires a subcommand: list | show")
        }
        let subArgs = Array(args.dropFirst())

        switch sub {
        case "list":
            try cmdTransfersList(home: home, args: subArgs, json: json)
        case "show":
            try cmdTransfersShow(home: home, args: subArgs, json: json)
        default:
            throw CLIError.usage("Unknown transfers subcommand: \(sub)")
        }
    }

    private func cmdTransfersList(home: PeerHome, args: [String], json: Bool) throws {
        let store = try AethosStore(path: home.storeSQLitePath)
        let transfers = try store.listTransfers()

        if json {
            let arr = transfers.map { transferToDict($0) }
            let obj: [String: Any] = ["transfers": arr]
            print(jsonString(obj))
        } else {
            if transfers.isEmpty {
                print("No transfers.")
            } else {
                for t in transfers {
                    let progress: String
                    switch t.direction {
                    case .outbound:
                        progress = "parts_sent=\(t.partsSent)/\(t.partsTotal) bytes_sent=\(t.bytesSent)/\(t.bytesTotal)"
                    case .inbound:
                        progress = "parts_received=\(t.partsReceived)/\(t.partsTotal) bytes_received=\(t.bytesReceived)/\(t.bytesTotal)"
                    }
                    var line = "\(t.transferId)  \(t.direction.rawValue)  \(t.status.rawValue)  \(progress)"
                    if let f = t.originalFilename {
                        line += "  file=\(f)"
                    }
                    print(line)
                }
            }
        }
    }

    private func cmdTransfersShow(home: PeerHome, args: [String], json: Bool) throws {
        guard let transferId = args.first, !transferId.isEmpty else {
            throw CLIError.usage("transfers show requires <transfer_id>")
        }

        let store = try AethosStore(path: home.storeSQLitePath)
        guard let t = try store.getTransfer(id: transferId) else {
            throw CLIError.usage("Transfer not found: \(transferId)")
        }

        if json {
            let obj: [String: Any] = ["transfer": transferToDict(t)]
            print(jsonString(obj))
        } else {
            print("transfer_id: \(t.transferId)")
            print("direction:   \(t.direction.rawValue)")
            print("status:      \(t.status.rawValue)")
            print("peer_from:   \(t.peerFrom)")
            print("peer_to:     \(t.peerTo)")
            if let f = t.originalFilename {
                print("filename:    \(f)")
            }
            print("bytes_total: \(t.bytesTotal)")
            print("bytes_sent:  \(t.bytesSent)")
            print("bytes_recv:  \(t.bytesReceived)")
            print("parts_total: \(t.partsTotal)")
            print("parts_sent:  \(t.partsSent)")
            print("parts_recv:  \(t.partsReceived)")
            if let h = t.manifestHash { print("manifest:    \(h)") }
            if let h = t.payloadHash { print("payload:     \(h)") }
            print("verified:    \(t.verified)")
            if let e = t.lastError { print("error:       \(e)") }
            print("created_at:  \(iso8601(t.createdAt))")
            print("updated_at:  \(iso8601(t.updatedAt))")
        }
    }

    // MARK: - Helpers

    private func buildChunkToManifestMap(home: PeerHome, fm: FileManager) -> [Data: String] {
        var mapping: [Data: String] = [:]
        let manifestFiles = (try? fm.contentsOfDirectory(at: home.transportManifestCacheDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for file in manifestFiles where file.pathExtension == "bin" {
            guard let bytes = try? Data(contentsOf: file) else { continue }
            guard let parsed = try? parseManifestCanonical(bytes) else { continue }
            let manifestId = AethosIDs.manifestId(canonicalBytes: bytes)
            let manifestHex = Hex.encode(manifestId)
            for cId in parsed.chunkIds {
                mapping[cId] = manifestHex
            }
        }
        return mapping
    }

    private func countBadFiles(in dir: URL, fileManager: FileManager) -> Int {
        let entries = (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return entries.filter { $0.lastPathComponent.contains(".bad") }.count
    }

    private func loadSendCursors(from url: URL) throws -> [String: UInt16] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode([String: UInt16].self, from: data)
        return decoded
    }

    private func saveSendCursors(_ cursors: [String: UInt16], to url: URL) throws {
        let data = try JSONEncoder().encode(cursors)
        try data.write(to: url, options: [.atomic])
    }

    private func tryReassembleCachedManifests(home: PeerHome, store: AethosStore) throws -> Int {
        let fm = FileManager.default
        let manifestFiles = (try? fm.contentsOfDirectory(at: home.transportManifestCacheDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var deliveredCount = 0

        for file in manifestFiles where file.pathExtension == "bin" {
            let manifestBytes = try Data(contentsOf: file)
            let (totalSize, chunkIds) = try parseManifestCanonical(manifestBytes)
            let manifest = ManifestV1(totalSize: totalSize, chunkIds: chunkIds)

            var chunksById: [Data: Data] = [:]
            chunksById.reserveCapacity(chunkIds.count)
            var all = true
            for id in chunkIds {
                if let bytes = try store.getChunk(id: id) {
                    chunksById[id] = bytes
                } else {
                    all = false
                    break
                }
            }
            guard all else { continue }

            do {
                let rebuilt = try Chunking.reassemble(chunksById: chunksById, manifest: manifest)
                let manifestIdData = AethosIDs.manifestId(canonicalBytes: manifestBytes)
                let outName = "reassembled-\(manifestIdData.hexString).bin"
                let outURL = home.transportArchiveDir.appendingPathComponent(outName, isDirectory: false)
                if !fm.fileExists(atPath: outURL.path) {
                    try rebuilt.write(to: outURL, options: [.atomic])
                    deliveredCount += 1

                    // Mark inbound transfer as complete
                    let manifestHashHex = manifestIdData.hexString
                    if var transfer = try store.getTransferByManifestHash(manifestHashHex, direction: .inbound) {
                        transfer.status = .complete
                        transfer.verified = true
                        transfer.payloadHash = AethosIDs.sha256(rebuilt).hexString
                        transfer.updatedAt = Date()
                        transfer.lastActivityAt = Date()
                        try store.updateTransfer(transfer)
                    }

                    // Generate and enqueue a receipt so the sender can observe completion.
                    // Look up the envelope for this manifest from the inbox.
                    let envelopeId = try findEnvelopeIdForManifest(manifestIdData, store: store)
                    let receipt = ReceiptV1(
                        envelopeId: envelopeId ?? Data(),
                        manifestId: manifestIdData,
                        receivedAtUnixMs: UInt64(Date().timeIntervalSince1970 * 1000)
                    )
                    let receiptBytes = CanonicalEncoderV1.encode(receipt)
                    let receiptId = AethosIDs.receiptId(from: receipt)
                    try store.enqueue(item: OutboxItem(
                        id: receiptId, kind: .receipt, payload: receiptBytes, enqueuedAt: Date()
                    ))
                }
            } catch {
                // Mark inbound transfer as failed on integrity mismatch
                let manifestIdData = AethosIDs.manifestId(canonicalBytes: manifestBytes)
                let manifestHashHex = manifestIdData.hexString
                if var transfer = try store.getTransferByManifestHash(manifestHashHex, direction: .inbound) {
                    transfer.status = .failed
                    transfer.lastError = String(describing: error)
                    transfer.updatedAt = Date()
                    transfer.lastActivityAt = Date()
                    try store.updateTransfer(transfer)
                }
            }
        }

        return deliveredCount
    }

    // MARK: - Canonical parsing

    private func parseManifestCanonical(_ bytes: Data) throws -> (totalSize: Int, chunkIds: [Data]) {
        var r = CanonicalReader(bytes)
        _ = r.readUInt8() // version
        let type = r.readUInt8()
        guard type == CanonicalEncoderV1.TypeDiscriminator.manifest.rawValue else {
            throw CLIError.usage("manifest canonical bytes have wrong type")
        }

        var total: Int = 0
        var chunkIds: [Data] = []

        while !r.isAtEnd {
            guard let fid = r.readUInt8() else { break }
            guard let len = r.readUInt32() else { break }
            guard let raw = r.readData(count: Int(len)) else { break }

            switch fid {
            case CanonicalEncoderV1.ManifestField.totalSize.rawValue:
                if raw.count == 8 {
                    total = Int(CanonicalReader.readUInt64BE(raw))
                }
            case CanonicalEncoderV1.ManifestField.chunkIds.rawValue:
                chunkIds = try parseDataArray(raw)
            default:
                break
            }
        }

        return (total, chunkIds)
    }

    private struct ParsedEnvelope {
        let toWayfarerId: Data
        let manifestId: Data
        let body: Data
    }

    private func parseEnvelopeCanonical(_ bytes: Data) throws -> ParsedEnvelope {
        var r = CanonicalReader(bytes)
        _ = r.readUInt8() // version
        let type = r.readUInt8()
        guard type == CanonicalEncoderV1.TypeDiscriminator.envelope.rawValue else {
            throw CLIError.usage("envelope canonical bytes have wrong type")
        }

        var toWayfarerId = Data()
        var manifestId = Data()
        var body = Data()

        while !r.isAtEnd {
            guard let fid = r.readUInt8() else { break }
            guard let len = r.readUInt32() else { break }
            guard let raw = r.readData(count: Int(len)) else { break }

            switch fid {
            case CanonicalEncoderV1.EnvelopeField.toWayfarerId.rawValue:
                toWayfarerId = raw
            case CanonicalEncoderV1.EnvelopeField.manifestId.rawValue:
                manifestId = raw
            case CanonicalEncoderV1.EnvelopeField.body.rawValue:
                body = raw
            default:
                break
            }
        }

        return ParsedEnvelope(toWayfarerId: toWayfarerId, manifestId: manifestId, body: body)
    }

    private struct ParsedReceipt {
        let envelopeId: Data
        let manifestId: Data
        let receivedAtUnixMs: UInt64
    }

    private func parseReceiptCanonical(_ bytes: Data) throws -> ParsedReceipt {
        var r = CanonicalReader(bytes)
        _ = r.readUInt8() // version
        let type = r.readUInt8()
        guard type == CanonicalEncoderV1.TypeDiscriminator.receipt.rawValue else {
            throw CLIError.usage("receipt canonical bytes have wrong type")
        }

        var envelopeId = Data()
        var manifestId = Data()
        var receivedAtUnixMs: UInt64 = 0

        while !r.isAtEnd {
            guard let fid = r.readUInt8() else { break }
            guard let len = r.readUInt32() else { break }
            guard let raw = r.readData(count: Int(len)) else { break }

            switch fid {
            case CanonicalEncoderV1.ReceiptField.envelopeId.rawValue:
                envelopeId = raw
            case CanonicalEncoderV1.ReceiptField.manifestId.rawValue:
                manifestId = raw
            case CanonicalEncoderV1.ReceiptField.receivedAtUnixMs.rawValue:
                if raw.count == 8 {
                    receivedAtUnixMs = CanonicalReader.readUInt64BE(raw)
                }
            default:
                break
            }
        }

        return ParsedReceipt(envelopeId: envelopeId, manifestId: manifestId, receivedAtUnixMs: receivedAtUnixMs)
    }

    /// Look up the envelopeId that references a given manifestId from inbox envelope items.
    private func findEnvelopeIdForManifest(_ manifestId: Data, store: AethosStore) throws -> Data? {
        let envelopes = try store.listInboxByKind(.envelope)
        for item in envelopes {
            if let env = try? parseEnvelopeCanonical(item.payload) {
                if env.manifestId == manifestId {
                    return item.id
                }
            }
        }
        return nil
    }

    private func parseDataArray(_ raw: Data) throws -> [Data] {
        var r = CanonicalReader(raw)
        guard let count = r.readUInt32() else { return [] }
        var out: [Data] = []
        out.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let len = r.readUInt32() else { break }
            guard let b = r.readData(count: Int(len)) else { break }
            out.append(b)
        }
        return out
    }

    private struct CanonicalReader {
        private let data: Data
        private var offset: Int = 0

        init(_ data: Data) { self.data = data }
        var isAtEnd: Bool { offset >= data.count }

        mutating func readUInt8() -> UInt8? {
            guard offset + 1 <= data.count else { return nil }
            let v = data[offset]
            offset += 1
            return v
        }

        mutating func readUInt32() -> UInt32? {
            guard let b0 = readUInt8(), let b1 = readUInt8(), let b2 = readUInt8(), let b3 = readUInt8() else { return nil }
            return (UInt32(b0) << 24) | (UInt32(b1) << 16) | (UInt32(b2) << 8) | UInt32(b3)
        }

        mutating func readData(count: Int) -> Data? {
            guard count >= 0, offset + count <= data.count else { return nil }
            let slice = data[offset..<offset + count]
            offset += count
            return Data(slice)
        }

        static func readUInt64BE(_ data: Data) -> UInt64 {
            var v: UInt64 = 0
            for b in data.prefix(8) {
                v = (v << 8) | UInt64(b)
            }
            return v
        }
    }

    // MARK: - Arg parsing

    private func parseKeyValues(_ args: [String]) throws -> [String: String] {
        var out: [String: String] = [:]
        var i = 0
        while i < args.count {
            let k = args[i]
            if k.hasPrefix("--") {
                guard i + 1 < args.count else {
                    throw CLIError.usage("Missing value for \(k)")
                }
                out[k] = args[i + 1]
                i += 2
            } else {
                throw CLIError.usage("Unexpected arg: \(k)")
            }
        }
        return out
    }

    // MARK: - JSON serialization

    private func transferToDict(_ t: Transfer) -> [String: Any] {
        var d: [String: Any] = [
            "transfer_id": t.transferId,
            "direction": t.direction.rawValue,
            "status": t.status.rawValue,
            "peer_from": t.peerFrom,
            "peer_to": t.peerTo,
            "created_at": iso8601(t.createdAt),
            "updated_at": iso8601(t.updatedAt),
            "last_activity_at": iso8601(t.lastActivityAt),
            "bytes_total": t.bytesTotal,
            "bytes_sent": t.bytesSent,
            "bytes_received": t.bytesReceived,
            "parts_total": Int(t.partsTotal),
            "parts_sent": Int(t.partsSent),
            "parts_received": Int(t.partsReceived),
            "verified": t.verified,
        ]
        if let v = t.originalFilename { d["original_filename"] = v }
        if let v = t.manifestHash { d["manifest_hash"] = v }
        if let v = t.payloadHash { d["payload_hash"] = v }
        if let v = t.lastError { d["last_error"] = v }
        return d
    }

    private func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    private func jsonString(_ obj: [String: Any]) -> String {
        // Manual JSON serialization for stable, sorted output
        return serializeJSON(obj, indent: 0)
    }

    private func serializeJSON(_ value: Any, indent: Int) -> String {
        let pad = String(repeating: "  ", count: indent)
        let innerPad = String(repeating: "  ", count: indent + 1)

        if let dict = value as? [String: Any] {
            if dict.isEmpty { return "{}" }
            let keys = dict.keys.sorted()
            var lines: [String] = []
            for key in keys {
                let val = serializeJSON(dict[key]!, indent: indent + 1)
                lines.append("\(innerPad)\(escapeJSONString(key)): \(val)")
            }
            return "{\n\(lines.joined(separator: ",\n"))\n\(pad)}"
        }

        if let arr = value as? [[String: Any]] {
            if arr.isEmpty { return "[]" }
            var items: [String] = []
            for item in arr {
                items.append("\(innerPad)\(serializeJSON(item, indent: indent + 1))")
            }
            return "[\n\(items.joined(separator: ",\n"))\n\(pad)]"
        }

        if let arr = value as? [Any] {
            if arr.isEmpty { return "[]" }
            var items: [String] = []
            for item in arr {
                items.append("\(innerPad)\(serializeJSON(item, indent: indent + 1))")
            }
            return "[\n\(items.joined(separator: ",\n"))\n\(pad)]"
        }

        if let s = value as? String {
            return escapeJSONString(s)
        }

        if let b = value as? Bool {
            return b ? "true" : "false"
        }

        if let n = value as? Int64 {
            return "\(n)"
        }

        if let n = value as? Int32 {
            return "\(n)"
        }

        if let n = value as? Int {
            return "\(n)"
        }

        return "null"
    }

    private func escapeJSONString(_ s: String) -> String {
        var out = "\""
        for c in s {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(c)
            }
        }
        out += "\""
        return out
    }

    // MARK: - Usage

    static let usage = """
    Usage:
      aethos <command> [--home <path>] [options]

    Commands:
      init             Initialize peer home (dirs, store, identity)
      status           Show peer home, identity, and paths
      send             Queue a file for delivery (file -> chunks + manifest/envelope)
      ingest           Read frames from inbox and store them
      pump             Plan + write frames to outbox
      transfers list   List all transfers
      transfers show   Show details for a transfer

    Global options:
      --home <path>    Peer home directory (default: ./peer)
      --json           Output in JSON format (status, transfers list, transfers show)

    Command options:
      send   --file <path> --to <wayfarerIdHex>
      ingest --max <n>
      pump   --max-bytes <n> --max-items <n>
      transfers show <transfer_id>
    """
}

do {
    try CLI(args: CommandLine.arguments).run()
} catch let CLIError.usage(msg) {
    FileHandle.standardError.write(Data("\(msg)\n".utf8))
    exit(2)
} catch {
    FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
    exit(1)
}
