import AethosCore
import AethosCLILib
import Foundation

enum CLIError: Swift.Error {
    case usage(String)
}

struct CLI {
    let args: [String]

    private enum JSONMode {
        case none
        case legacy
        case contractV1
    }

    func run() throws {
        var argv = args
        _ = argv.first
        argv = Array(argv.dropFirst())

        guard let command = argv.first else {
            throw CLIError.usage(Self.usage)
        }
        argv = Array(argv.dropFirst())

        let (home, rest, jsonMode) = try parseGlobalArgs(from: argv)
        let contractCommandName = contractV1CommandName(command: command, args: rest)
        do {
            switch command {
            case "init":
                try cmdInit(home: home, args: rest)
            case "status":
                try cmdStatus(home: home, args: rest, json: jsonMode)
            case "send":
                try cmdSend(home: home, args: rest)
            case "ingest":
                try cmdIngest(home: home, args: rest)
            case "pump":
                try cmdPump(home: home, args: rest)
            case "transfers":
                try cmdTransfers(home: home, args: rest, json: jsonMode)
            case "inventory":
                try cmdInventory(home: home, args: rest, json: jsonMode)
            case "peers":
                try cmdPeers(home: home, args: rest, json: jsonMode)
            case "relay":
                try cmdRelay(home: home, args: rest, json: jsonMode)
            case "serve":
                try cmdServe(home: home, args: rest)
            case "http":
                try cmdHttp(home: home, args: rest, json: jsonMode)
            case "remote":
                try cmdRemote(home: home, args: rest, json: jsonMode)
            case "messages":
                try cmdMessages(home: home, args: rest, json: jsonMode)
            case "help", "--help", "-h":
                print(Self.usage)
            default:
                throw CLIError.usage("Unknown command: \(command)\n\n\(Self.usage)")
            }
        } catch {
            if jsonMode == .contractV1 {
                let err = CLIContractV1.error(command: contractCommandName, type: "error", message: String(describing: error))
                FileHandle.standardError.write(Data("\(CLIJSON.serializeJSON(err, indent: 0))\n".utf8))
                exit(1)
            }
            throw error
        }
    }

    private func contractV1CommandName(command: String, args: [String]) -> String {
        // Prefer full command path for contract v1 error reporting.
        // Example: `http exchange` -> `http.exchange`.
        let supportsSub: Set<String> = ["transfers", "inventory", "peers", "relay", "http", "remote", "messages"]
        guard supportsSub.contains(command) else { return command }
        guard let sub = args.first, !sub.hasPrefix("-") else { return command }
        return "\(command).\(sub)"
    }

    private func parseGlobalArgs(from args: [String]) throws -> (PeerHome, [String], JSONMode) {
        var rest: [String] = []
        var i = 0
        var homeURL: URL? = nil
        var jsonLegacy = false
        var jsonV1 = false

        while i < args.count {
            let a = args[i]
            if a == "--home" {
                guard i + 1 < args.count else { throw CLIError.usage("--home requires a path") }
                homeURL = URL(fileURLWithPath: args[i + 1])
                i += 2
                continue
            }
            if a == "--json" {
                jsonLegacy = true
                i += 1
                continue
            }
            if a == "--json-v1" {
                jsonV1 = true
                i += 1
                continue
            }
            rest.append(a)
            i += 1
        }

        let mode: JSONMode
        if jsonV1 {
            mode = .contractV1
        } else if jsonLegacy {
            mode = .legacy
        } else {
            mode = .none
        }

        return (PeerHome(root: homeURL ?? PeerHome.defaultRootURL()), rest, mode)
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

    private func cmdStatus(home: PeerHome, args: [String], json: JSONMode) throws {
        guard args.isEmpty else {
            throw CLIError.usage("status takes no positional args")
        }

        let fm = FileManager.default
        let storeExists = fm.fileExists(atPath: home.storeSQLitePath.path)

        var wayfarerIdHex: String? = nil
        var shortId: String? = nil
        var identity: IdentityV1? = nil
        do {
            let identityStore = DefaultIdentityStore(directory: home.identityDir)
            let identityManager = IdentityManager(store: identityStore)
            identity = try identityManager.loadOrCreate()
            wayfarerIdHex = identity!.wayfarerId.hexString
            shortId = identity!.shortId
        } catch {}

        if json != .none {
            if json == .contractV1 {
                if !storeExists {
                    print(jsonString(CLIContractV1.status(storeExists: storeExists, identity: identity)))
                    return
                }

                let store = try AethosStore(path: home.storeSQLitePath)
                let transfers = try store.listTransfers()
                let transfersSummary: [String: Any] = [
                    "total": transfers.count,
                    "queued": transfers.filter { $0.status == .queued }.count,
                    "sending": transfers.filter { $0.status == .sending }.count,
                    "receiving": transfers.filter { $0.status == .receiving }.count,
                    "complete": transfers.filter { $0.status == .complete }.count,
                    "failed": transfers.filter { $0.status == .failed }.count,
                    "evicted": transfers.filter { $0.evicted }.count,
                ]

                let nowEpoch = AethosStore.epochSeconds(Date())
                let (totalPeers, stalePeers) = try store.countPeers(staleAfterSeconds: 86400, now: nowEpoch)
                let peersSummary: [String: Any] = [
                    "total": totalPeers,
                    "stale": stalePeers,
                    "recently_seen": totalPeers - stalePeers,
                ]

                print(jsonString(CLIContractV1.status(
                    storeExists: storeExists,
                    identity: identity,
                    transfersSummary: transfersSummary,
                    peersSummary: peersSummary
                )))
                return
            }
            var identityDict: [String: Any] = [
                "wayfarerId": wayfarerIdHex ?? "",
                "shortId": shortId ?? "",
                "self_certifying": identity?.isSelfCertifying ?? false,
            ]
            if let id = identity {
                identityDict["publicKey"] = id.signingPublicKeyHex
                identityDict["exchangePublicKey"] = id.exchangePublicKeyHex
                identityDict["keyType"] = IdentityV1.keyType
                identityDict["keyFingerprint"] = id.keyFingerprint
            }

            var obj: [String: Any] = [
                "peer": [
                    "home": home.root.path,
                    "wayfarerId": wayfarerIdHex ?? "",
                    "shortId": shortId ?? "",
                ],
                "identity": identityDict,
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
                var tSummary: [String: Any] = [:]
                tSummary["total"] = transfers.count
                tSummary["queued"] = transfers.filter { $0.status == .queued }.count
                tSummary["sending"] = transfers.filter { $0.status == .sending }.count
                tSummary["receiving"] = transfers.filter { $0.status == .receiving }.count
                tSummary["complete"] = transfers.filter { $0.status == .complete }.count
                tSummary["failed"] = transfers.filter { $0.status == .failed }.count
                tSummary["evicted"] = transfers.filter { $0.evicted }.count
                obj["transfers_summary"] = tSummary

                var cSummary: [String: Any] = [:]
                cSummary["origin"] = transfers.filter { $0.custody == .origin }.count
                cSummary["relay"] = transfers.filter { $0.custody == .relay }.count
                cSummary["inbound"] = transfers.filter { $0.custody == .inbound }.count
                cSummary["relay_cache_bytes"] = (try? store.relayCacheBytes()) ?? Int64(0)
                cSummary["relay_forwardable_count"] = (try? store.countForwardableRelayTransfers(now: Date())) ?? 0
                obj["custody_summary"] = cSummary

                // Peers summary
                let nowEpoch = AethosStore.epochSeconds(Date())
                let (totalPeers, stalePeers) = try store.countPeers(staleAfterSeconds: 86400, now: nowEpoch)
                obj["peers_summary"] = [
                    "total": totalPeers,
                    "stale": stalePeers,
                    "recently_seen": totalPeers - stalePeers,
                ] as [String: Any]
            }

            print(jsonString(obj))
        } else {
            print("Peer home:\n  \(home.root.path)")
            print("Store:\n  \(home.storeSQLitePath.path) (exists: \(storeExists ? "yes" : "no"))")
            print("Transport dirs:\n  inbox=\(home.transportInboxDir.path)\n  outbox=\(home.transportOutboxDir.path)\n  archive=\(home.transportArchiveDir.path)")
            if let wid = wayfarerIdHex, let sid = shortId, let id = identity {
                print("Identity:\n  wayfarerId=\(wid)\n  shortId=\(sid)")
                print("  keyType=\(IdentityV1.keyType)")
                print("  publicKey=\(id.signingPublicKeyHex)")
                print("  fingerprint=\(id.keyFingerprint)")
                print("  selfCertifying=\(id.isSelfCertifying)")
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
                                transfer.completedAt = Date()
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
                    // and detect relay scenario (destination != local)
                    if let envelopeInfo = try? parseEnvelopeCanonical(bytes) {
                        let manifestHashHex = Hex.encode(envelopeInfo.manifestId)
                        let destHex = Hex.encode(envelopeInfo.toWayfarerId)

                        if var transfer = try store.getTransferByManifestHash(manifestHashHex, direction: .inbound) {
                            var changed = false
                            // Relay detection: if destination is not us, mark as relay
                            if destHex != localWayfarerHex && transfer.custody != .relay {
                                transfer.custody = .relay
                                transfer.peerTo = destHex
                                changed = true
                            }
                            if transfer.originalFilename == nil,
                               let filename = String(data: envelopeInfo.body, encoding: .utf8), !filename.isEmpty {
                                transfer.originalFilename = filename
                                changed = true
                            }
                            if changed {
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

                        // Check if we already have an envelope for this manifest to detect relay
                        let relayInfo = try detectRelayFromEnvelopes(
                            manifestId: id, store: store, localWayfarerHex: localWayfarerHex
                        )

                        let transfer = Transfer(
                            transferId: Transfer.newId(),
                            direction: .inbound,
                            peerFrom: "",
                            peerTo: relayInfo?.destHex ?? localWayfarerHex,
                            createdAt: Date(),
                            updatedAt: Date(),
                            lastActivityAt: Date(),
                            status: .receiving,
                            bytesTotal: Int64(totalSize),
                            partsTotal: Int32(chunkIds.count),
                            manifestHash: manifestHashHex,
                            custody: relayInfo != nil ? .relay : nil
                        )
                        try store.createTransfer(transfer)

                        // Update chunk→manifest mapping
                        for cId in chunkIds {
                            chunkToManifestHash[cId] = manifestHashHex
                        }
                    }
                case .inventory:
                    try store.recordReceived(item: InboxItem(id: id, kind: .inventory, payload: bytes, receivedAt: Date()))
                    storedItems += 1

                case .inventoryRequest:
                    try store.recordReceived(item: InboxItem(id: id, kind: .inventoryRequest, payload: bytes, receivedAt: Date()))
                    storedItems += 1

                    // Pull behavior: re-enqueue content for each requested manifest hash
                    let request = try CanonicalEncoderV1.decodeInventoryRequest(canonical: bytes)
                    for wantHash in request.want {
                        try replayManifestContent(manifestHash: wantHash, store: store, home: home, fm: fm)
                    }

                case .message:
                    try store.recordReceived(item: InboxItem(id: id, kind: .message, payload: bytes, receivedAt: Date()))
                    storedItems += 1

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

        // Observe peers from inbound transfers that have a known peerFrom
        let inboundTransfers = try store.listTransfers(direction: .inbound)
        let nowEpoch = AethosStore.epochSeconds(Date())
        for t in inboundTransfers {
            if !t.peerFrom.isEmpty && t.peerFrom.count == 64 {
                try store.upsertPeerSeen(wayfarerId: t.peerFrom, now: nowEpoch)
            }
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

            case .inventory, .inventoryRequest:
                let frame = frames[0]
                if frame.sizeBytes > remainingBytes { continue }
                try link.send(frame)
                sentFrames += 1
                sentBytes += frame.sizeBytes
                remainingBytes -= frame.sizeBytes
                remainingItems -= 1

            case .message:
                let frame = frames[0]
                if frame.sizeBytes > remainingBytes { continue }
                try link.send(frame)
                sentFrames += 1
                sentBytes += frame.sizeBytes
                remainingBytes -= frame.sizeBytes
                remainingItems -= 1
                // No outbox state transition; messages are durable records, not delivery-tracked like receipts.

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

    private func cmdTransfers(home: PeerHome, args: [String], json: JSONMode) throws {
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

    private func cmdTransfersList(home: PeerHome, args: [String], json: JSONMode) throws {
        let store = try AethosStore(path: home.storeSQLitePath)
        let transfers = try store.listTransfers()

        if json != .none {
            if json == .contractV1 {
                print(jsonString(CLIContractV1.transfersList(transfers)))
            } else {
                let arr = transfers.map { transferToDict($0) }
                let obj: [String: Any] = ["transfers": arr]
                print(jsonString(obj))
            }
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
                    var line = "\(t.transferId)  \(t.direction.rawValue)  \(t.status.rawValue)  custody=\(t.custody.rawValue)  \(progress)"
                    if t.evicted {
                        line += "  [evicted]"
                    }
                    if let f = t.originalFilename {
                        line += "  file=\(f)"
                    }
                    print(line)
                }
            }
        }
    }

    private func cmdTransfersShow(home: PeerHome, args: [String], json: JSONMode) throws {
        guard let transferId = args.first, !transferId.isEmpty else {
            throw CLIError.usage("transfers show requires <transfer_id>")
        }

        let store = try AethosStore(path: home.storeSQLitePath)
        guard let t = try store.getTransfer(id: transferId) else {
            throw CLIError.usage("Transfer not found: \(transferId)")
        }

        if json != .none {
            if json == .contractV1 {
                print(jsonString(CLIContractV1.transfersShow(t)))
            } else {
                let obj: [String: Any] = ["transfer": transferToDict(t)]
                print(jsonString(obj))
            }
        } else {
            print("transfer_id: \(t.transferId)")
            print("direction:   \(t.direction.rawValue)")
            print("status:      \(t.status.rawValue)")
            print("custody:     \(t.custody.rawValue)")
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
            print("evicted:     \(t.evicted)")
            if let ttl = t.ttlSeconds { print("ttl_seconds: \(ttl)") }
            if let ea = t.expiresAt { print("expires_at:  \(iso8601(ea))") }
            if let ca = t.completedAt { print("completed_at: \(iso8601(ca))") }
            if let e = t.lastError { print("error:       \(e)") }
            print("created_at:  \(iso8601(t.createdAt))")
            print("updated_at:  \(iso8601(t.updatedAt))")
        }
    }

    // MARK: - inventory

    private func cmdInventory(home: PeerHome, args: [String], json: JSONMode) throws {
        guard let sub = args.first else {
            throw CLIError.usage("inventory requires a subcommand: advertise | request")
        }
        let subArgs = Array(args.dropFirst())

        switch sub {
        case "advertise":
            try cmdInventoryAdvertise(home: home, args: subArgs, json: json)
        case "request":
            try cmdInventoryRequest(home: home, args: subArgs, json: json)
        case "exchange":
            try cmdInventoryExchange(home: home, args: subArgs, json: json)
        case "gossip":
            try cmdInventoryGossip(home: home, args: subArgs, json: json)
        default:
            throw CLIError.usage("Unknown inventory subcommand: \(sub)")
        }
    }

    private func cmdInventoryAdvertise(home: PeerHome, args: [String], json: JSONMode) throws {
        try home.createDirectories()
        let store = try AethosStore(path: home.storeSQLitePath)

        let hashes = try store.listActiveManifestHashes()
        let now = Date()
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)

        let inventory = InventoryV1(manifests: hashes, generatedAtUnixMs: nowMs)
        let canonical = CanonicalEncoderV1.encode(inventory)
        let id = AethosIDs.sha256(canonical)

        try store.enqueue(item: OutboxItem(
            id: id,
            kind: .inventory,
            payload: canonical,
            enqueuedAt: now
        ))

        if json != .none {
            if json == .contractV1 {
                print(jsonString(CLIContractV1.inventoryAdvertise(manifests: hashes, generatedAtUnixMs: nowMs, enqueued: true)))
            } else {
                let obj: [String: Any] = [
                    "manifests": hashes,
                    "count": hashes.count,
                    "generatedAtUnixMs": nowMs,
                ]
                print(jsonString(obj))
            }
        } else {
            print("inventory advertise")
            print("  manifests=\(hashes.count)")
            for h in hashes {
                print("    \(h)")
            }
            print("  enqueued=true")
        }
    }

    private func cmdInventoryRequest(home: PeerHome, args: [String], json: JSONMode) throws {
        try home.createDirectories()
        let store = try AethosStore(path: home.storeSQLitePath)

        // Read inventory JSON from stdin
        let stdinData = FileHandle.standardInput.readDataToEndOfFile()
        guard !stdinData.isEmpty else {
            throw CLIError.usage("inventory request: expected inventory JSON on stdin")
        }

        guard let jsonObj = try JSONSerialization.jsonObject(with: stdinData) as? [String: Any] else {
            throw CLIError.usage("inventory request: stdin must be a JSON object")
        }

        // Extract manifests array from the JSON. Support both raw array and
        // the object format produced by `inventory advertise --json`.
        let remoteManifests: [String]
        if let arr = jsonObj["manifests"] as? [String] {
            remoteManifests = arr
        } else {
            throw CLIError.usage("inventory request: JSON must have a 'manifests' array of strings")
        }

        // Diff against local store
        var missing: [String] = []
        for hash in remoteManifests {
            let has = try store.hasManifest(hash)
            if !has {
                missing.append(hash)
            }
        }

        if !missing.isEmpty {
            let request = InventoryRequestV1(want: missing)
            let canonical = CanonicalEncoderV1.encode(request)
            let id = AethosIDs.sha256(canonical)

            try store.enqueue(item: OutboxItem(
                id: id,
                kind: .inventoryRequest,
                payload: canonical,
                enqueuedAt: Date()
            ))
        }

        if json != .none {
            if json == .contractV1 {
                print(jsonString(CLIContractV1.inventoryRequest(
                    remoteCount: remoteManifests.count,
                    want: missing,
                    enqueued: !missing.isEmpty
                )))
            } else {
                let obj: [String: Any] = [
                    "remote_count": remoteManifests.count,
                    "missing_count": missing.count,
                    "want": missing,
                ]
                print(jsonString(obj))
            }
        } else {
            print("inventory request")
            print("  remote=\(remoteManifests.count)")
            print("  missing=\(missing.count)")
            for h in missing {
                print("    \(h)")
            }
            if !missing.isEmpty {
                print("  enqueued=true")
            }
        }
    }

    // MARK: - inventory exchange

    /// Result of a single inventory exchange round with one peer.
    private struct ExchangeResult {
        var advertisedCount: Int = 0
        var advertisedTruncated: Bool = false
        var peerAdvertisedCount: Int = 0
        var missingOnPeerCount: Int = 0
        var requestedCount: Int = 0
        var requestedTruncated: Bool = false
        var replayedManifests: Int = 0
        var replayedChunks: Int = 0
        var receiptsReceived: Int = 0
        var status: String = "ok"
        var error: String? = nil
    }

    /// Shared exchange logic used by both `inventory exchange` and `inventory gossip`.
    private func performExchange(
        home: PeerHome,
        store: AethosStore,
        peerWayfarerHex: String,
        limit: Int,
        requestCap: Int
    ) throws -> ExchangeResult {
        var result = ExchangeResult()
        let fm = FileManager.default
        let now = Date()
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)

        // Track replay dedup within this exchange round
        var replayedManifests: Set<String> = []

        // === Step 1: Compute advertise set ===
        let totalAdvertisable = try store.countAdvertisableManifestHashes(now: now)
        let advertiseHashes = try store.listAdvertisableManifestHashes(limit: limit, now: now)
        result.advertisedCount = advertiseHashes.count
        result.advertisedTruncated = totalAdvertisable > advertiseHashes.count

        // === Step 2: Emit InventoryV1 ===
        let inventory = InventoryV1(manifests: advertiseHashes, generatedAtUnixMs: nowMs)
        let inventoryCanonical = CanonicalEncoderV1.encode(inventory)
        let inventoryId = AethosIDs.sha256(inventoryCanonical)

        try store.enqueue(item: OutboxItem(
            id: inventoryId,
            kind: .inventory,
            payload: inventoryCanonical,
            enqueuedAt: now
        ))

        // === Step 3: Ingest inbound frames already present in inbox ===
        let link = try FileDropLink(
            inboxDir: home.transportInboxDir,
            outboxDir: home.transportOutboxDir,
            archiveDir: home.transportArchiveDir
        )

        // Load identity for inbound transfer creation
        let identityStore = DefaultIdentityStore(directory: home.identityDir)
        let identityManager = IdentityManager(store: identityStore)
        let localIdentity = try identityManager.loadOrCreate()
        let localWayfarerHex = localIdentity.wayfarerId.hexString

        var chunkToManifestHash = buildChunkToManifestMap(home: home, fm: fm)

        // Ingest all available frames from inbox
        var keepIngesting = true
        while keepIngesting {
            guard let frame = try link.receive() else {
                keepIngesting = false
                break
            }

            let fragment = try CargoCodec.decode(frame)
            switch fragment {
            case let .metadata(type, id, bytes):
                switch CargoCodec.FrameType(rawValue: type) {
                case .receipt:
                    try store.recordReceived(item: InboxItem(id: id, kind: .receipt, payload: bytes, receivedAt: Date()))
                    result.receiptsReceived += 1
                    if let receiptInfo = try? parseReceiptCanonical(bytes) {
                        let manifestHashHex = Hex.encode(receiptInfo.manifestId)
                        if var transfer = try store.getTransferByManifestHash(manifestHashHex, direction: .outbound) {
                            if transfer.status == .sending || transfer.status == .queued {
                                transfer.status = .complete
                                transfer.verified = true
                                transfer.completedAt = Date()
                                transfer.updatedAt = Date()
                                transfer.lastActivityAt = Date()
                                try store.updateTransfer(transfer)
                            }
                        }
                    }
                case .envelope:
                    try store.recordReceived(item: InboxItem(id: id, kind: .envelope, payload: bytes, receivedAt: Date()))
                    if let envelopeInfo = try? parseEnvelopeCanonical(bytes) {
                        let manifestHashHex = Hex.encode(envelopeInfo.manifestId)
                        let destHex = Hex.encode(envelopeInfo.toWayfarerId)

                        if var transfer = try store.getTransferByManifestHash(manifestHashHex, direction: .inbound) {
                            var changed = false
                            if destHex != localWayfarerHex && transfer.custody != .relay {
                                transfer.custody = .relay
                                transfer.peerTo = destHex
                                changed = true
                            }
                            if transfer.originalFilename == nil,
                               let filename = String(data: envelopeInfo.body, encoding: .utf8), !filename.isEmpty {
                                transfer.originalFilename = filename
                                changed = true
                            }
                            if changed {
                                transfer.updatedAt = Date()
                                try store.updateTransfer(transfer)
                            }
                        }
                    }
                case .manifest:
                    try store.recordReceived(item: InboxItem(id: id, kind: .manifest, payload: bytes, receivedAt: Date()))
                    let manifestPath = home.transportManifestCacheDir.appendingPathComponent("\(Hex.encode(id)).bin")
                    if !fm.fileExists(atPath: manifestPath.path) {
                        try bytes.write(to: manifestPath, options: [.atomic])
                    }
                    let manifestHashHex = Hex.encode(id)
                    if try store.getTransferByManifestHash(manifestHashHex, direction: .inbound) == nil {
                        let (totalSize, chunkIds) = try parseManifestCanonical(bytes)

                        let relayInfo = try detectRelayFromEnvelopes(
                            manifestId: id, store: store, localWayfarerHex: localWayfarerHex
                        )

                        let transfer = Transfer(
                            transferId: Transfer.newId(),
                            direction: .inbound,
                            peerFrom: peerWayfarerHex,
                            peerTo: relayInfo?.destHex ?? localWayfarerHex,
                            createdAt: Date(),
                            updatedAt: Date(),
                            lastActivityAt: Date(),
                            status: .receiving,
                            bytesTotal: Int64(totalSize),
                            partsTotal: Int32(chunkIds.count),
                            manifestHash: manifestHashHex,
                            custody: relayInfo != nil ? .relay : nil
                        )
                        try store.createTransfer(transfer)
                        for cId in chunkIds {
                            chunkToManifestHash[cId] = manifestHashHex
                        }
                    }
                case .inventory:
                    try store.recordReceived(item: InboxItem(id: id, kind: .inventory, payload: bytes, receivedAt: Date()))
                case .inventoryRequest:
                    try store.recordReceived(item: InboxItem(id: id, kind: .inventoryRequest, payload: bytes, receivedAt: Date()))
                    let request = try CanonicalEncoderV1.decodeInventoryRequest(canonical: bytes)
                    for wantHash in request.want {
                        if !replayedManifests.contains(wantHash) {
                            try replayManifestContent(manifestHash: wantHash, store: store, home: home, fm: fm)
                            replayedManifests.insert(wantHash)
                            result.replayedManifests += 1
                        }
                    }

                case .message:
                    try store.recordReceived(item: InboxItem(id: id, kind: .message, payload: bytes, receivedAt: Date()))
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
                    for i in 0..<partCount {
                        guard let url = diskParts[i], let partData = try? Data(contentsOf: url) else {
                            full = Data()
                            break
                        }
                        full.append(partData)
                    }
                    if !full.isEmpty {
                        try store.putChunk(id: id, bytes: full, receivedAt: Date())
                        result.replayedChunks += 1
                        if let manifestHashHex = chunkToManifestHash[id] {
                            if var transfer = try store.getTransferByManifestHash(manifestHashHex, direction: .inbound) {
                                transfer.partsReceived += 1
                                transfer.bytesReceived += Int64(full.count)
                                transfer.lastActivityAt = Date()
                                transfer.updatedAt = Date()
                                try store.updateTransfer(transfer)
                            }
                        }
                        try? fm.removeItem(at: chunkDir)
                    }
                }
            }

            _ = try tryReassembleCachedManifests(home: home, store: store)
        }

        // === Step 4: Check for peer InventoryV1 in inbox ===
        let inboxInventories = try store.listInboxByKind(.inventory)
        var peerManifests: [String] = []
        for item in inboxInventories {
            if let decoded = try? CanonicalEncoderV1.decodeInventory(canonical: item.payload) {
                peerManifests = decoded.manifests
            }
        }
        result.peerAdvertisedCount = peerManifests.count

        if !peerManifests.isEmpty {
            let peerSet = Set(peerManifests)
            let myHashes = try store.listAdvertisableManifestHashes(limit: 1_000_000, now: now)

            var missingOnPeerAll: [String] = []
            for hash in myHashes {
                if !peerSet.contains(hash) {
                    missingOnPeerAll.append(hash)
                }
            }
            result.missingOnPeerCount = missingOnPeerAll.count

            // === Step 5: Cap and emit InventoryRequestV1 for missing_on_peer ===
            let requested: [String]
            if missingOnPeerAll.count > requestCap {
                result.requestedTruncated = true
                requested = Array(missingOnPeerAll.prefix(requestCap))
            } else {
                requested = missingOnPeerAll
            }
            result.requestedCount = requested.count

            if !requested.isEmpty {
                let request = InventoryRequestV1(want: requested)
                let requestCanonical = CanonicalEncoderV1.encode(request)
                let requestId = AethosIDs.sha256(requestCanonical)

                try store.enqueue(item: OutboxItem(
                    id: requestId,
                    kind: .inventoryRequest,
                    payload: requestCanonical,
                    enqueuedAt: now
                ))
            }
        }

        // === Step 6: Ingest inbound InventoryRequestV1 and trigger replay ===
        let inboxRequests = try store.listInboxByKind(.inventoryRequest)
        for item in inboxRequests {
            if let decoded = try? CanonicalEncoderV1.decodeInventoryRequest(canonical: item.payload) {
                for wantHash in decoded.want {
                    if !replayedManifests.contains(wantHash) {
                        try replayManifestContent(manifestHash: wantHash, store: store, home: home, fm: fm)
                        replayedManifests.insert(wantHash)
                        result.replayedManifests += 1
                    }
                }
            }
        }

        return result
    }

    private func cmdInventoryExchange(home: PeerHome, args: [String], json: JSONMode) throws {
        let parsed = try parseKeyValues(args)

        guard let withPeerHex = parsed["--with"], !withPeerHex.isEmpty else {
            throw CLIError.usage("inventory exchange requires --with <PEER_WAYFARER_ID>")
        }
        guard let _ = Hex.decode(withPeerHex), withPeerHex.count == 64 else {
            throw CLIError.usage("--with must be a 64-char hex wayfarer ID")
        }

        let limit = Int(parsed["--limit"] ?? "500") ?? 500
        let requestCap = Int(parsed["--request-cap"] ?? "200") ?? 200
        guard limit > 0 else { throw CLIError.usage("--limit must be > 0") }
        guard requestCap > 0 else { throw CLIError.usage("--request-cap must be > 0") }

        try home.createDirectories()
        let store = try AethosStore(path: home.storeSQLitePath)

        // Record peer observation
        let nowEpoch = AethosStore.epochSeconds(Date())
        try store.upsertPeerSeen(wayfarerId: withPeerHex, now: nowEpoch)

        let result = try performExchange(
            home: home, store: store,
            peerWayfarerHex: withPeerHex,
            limit: limit, requestCap: requestCap
        )

        // Mark exchange completed
        if result.status == "ok" {
            try store.markPeerExchanged(wayfarerId: withPeerHex, now: AethosStore.epochSeconds(Date()))
        }

        if json != .none {
            let exchange: [String: Any] = [
                "advertised_count": result.advertisedCount,
                "advertised_truncated": result.advertisedTruncated,
                "peer_advertised_count": result.peerAdvertisedCount,
                "missing_on_peer_count": result.missingOnPeerCount,
                "requested_count": result.requestedCount,
                "requested_truncated": result.requestedTruncated,
                "replayed_manifests": result.replayedManifests,
                "replayed_chunks": result.replayedChunks,
                "receipts_received": result.receiptsReceived,
            ]
            if json == .contractV1 {
                print(jsonString(CLIContractV1.inventoryExchange(peerWayfarerId: withPeerHex, exchange: exchange)))
            } else {
                print(jsonString(["exchange": exchange]))
            }
        } else {
            print("inventory exchange")
            print("  advertised_count=\(result.advertisedCount)")
            print("  advertised_truncated=\(result.advertisedTruncated)")
            print("  peer_advertised_count=\(result.peerAdvertisedCount)")
            print("  missing_on_peer_count=\(result.missingOnPeerCount)")
            print("  requested_count=\(result.requestedCount)")
            print("  requested_truncated=\(result.requestedTruncated)")
            print("  replayed_manifests=\(result.replayedManifests)")
            print("  replayed_chunks=\(result.replayedChunks)")
            print("  receipts_received=\(result.receiptsReceived)")
        }
    }

    // MARK: - inventory gossip

    private func cmdInventoryGossip(home: PeerHome, args: [String], json: JSONMode) throws {
        let parsed = try parseKeyValues(args)

        let limitPeers = Int(parsed["--limit-peers"] ?? "10") ?? 10
        let peerLimit = Int(parsed["--peer-limit"] ?? "500") ?? 500
        let requestCap = Int(parsed["--request-cap"] ?? "200") ?? 200
        let staleAfter = Int64(parsed["--stale-after"] ?? "86400") ?? 86400
        let maxRounds = Int(parsed["--max-rounds"] ?? "\(limitPeers)") ?? limitPeers
        let includeStale = parsed["--include-stale"] != nil

        guard limitPeers > 0 else { throw CLIError.usage("--limit-peers must be > 0") }
        guard peerLimit > 0 else { throw CLIError.usage("--peer-limit must be > 0") }
        guard requestCap > 0 else { throw CLIError.usage("--request-cap must be > 0") }

        try home.createDirectories()
        let store = try AethosStore(path: home.storeSQLitePath)
        let nowEpoch = AethosStore.epochSeconds(Date())

        // Select peers from store: prioritize those never exchanged or least recently exchanged
        let peers = try store.listPeers(
            limit: limitPeers,
            sort: .lastExchangeAsc,
            includeStale: includeStale,
            staleAfterSeconds: staleAfter,
            now: nowEpoch
        )

        // Load identity to exclude self
        let identityStore = DefaultIdentityStore(directory: home.identityDir)
        let identityManager = IdentityManager(store: identityStore)
        let localIdentity = try identityManager.loadOrCreate()
        let localWayfarerHex = localIdentity.wayfarerId.hexString

        // Filter out self
        let selectedPeers = peers.filter { $0.wayfarerId != localWayfarerHex }

        // Count all peers for summary
        let (totalPeers, _) = try store.countPeers(
            staleAfterSeconds: staleAfter,
            now: nowEpoch
        )

        var results: [[String: Any]] = []
        var exchangedOk = 0
        var exchangedFailed = 0
        var rounds = 0

        for peer in selectedPeers {
            if rounds >= maxRounds { break }
            rounds += 1

            var peerResult: [String: Any] = [
                "peer": [
                    "wayfarer_id": peer.wayfarerId,
                    "short_id": peer.shortId,
                ] as [String: Any],
                "selected": true,
            ]

            do {
                let exchangeResult = try performExchange(
                    home: home, store: store,
                    peerWayfarerHex: peer.wayfarerId,
                    limit: peerLimit, requestCap: requestCap
                )

                // Mark peer exchanged on success
                try store.markPeerExchanged(wayfarerId: peer.wayfarerId, now: AethosStore.epochSeconds(Date()))
                exchangedOk += 1

                peerResult["exchange"] = [
                    "advertised_count": exchangeResult.advertisedCount,
                    "advertised_truncated": exchangeResult.advertisedTruncated,
                    "peer_advertised_count": exchangeResult.peerAdvertisedCount,
                    "missing_on_peer_count": exchangeResult.missingOnPeerCount,
                    "requested_count": exchangeResult.requestedCount,
                    "requested_truncated": exchangeResult.requestedTruncated,
                    "replayed_manifests": exchangeResult.replayedManifests,
                    "replayed_chunks": exchangeResult.replayedChunks,
                    "receipts_received": exchangeResult.receiptsReceived,
                ] as [String: Any]
                peerResult["status"] = "ok"
            } catch {
                exchangedFailed += 1
                peerResult["status"] = "error"
                peerResult["error"] = String(describing: error)
            }

            results.append(peerResult)
        }

        if json != .none {
            let summary: [String: Any] = [
                "peers_considered": totalPeers,
                "peers_selected": selectedPeers.count,
                "peers_exchanged_ok": exchangedOk,
                "peers_failed": exchangedFailed,
            ]
            if json == .contractV1 {
                print(jsonString(CLIContractV1.inventoryGossip(
                    nowEpochSeconds: nowEpoch,
                    limitPeers: limitPeers,
                    peerLimit: peerLimit,
                    requestCap: requestCap,
                    staleAfterSeconds: staleAfter,
                    results: results,
                    summary: summary
                )))
            } else {
                let obj: [String: Any] = [
                    "gossip": [
                        "now": nowEpoch,
                        "limit_peers": limitPeers,
                        "peer_limit": peerLimit,
                        "request_cap": requestCap,
                        "stale_after_seconds": staleAfter,
                    ] as [String: Any],
                    "results": results,
                    "summary": summary,
                ]
                print(jsonString(obj))
            }
        } else {
            print("inventory gossip")
            print("  peers_considered=\(totalPeers)")
            print("  peers_selected=\(selectedPeers.count)")
            print("  peers_exchanged_ok=\(exchangedOk)")
            print("  peers_failed=\(exchangedFailed)")
            for r in results {
                if let peer = r["peer"] as? [String: Any],
                   let shortId = peer["short_id"] as? String {
                    let status = r["status"] as? String ?? "unknown"
                    print("  peer=\(shortId) status=\(status)")
                }
            }
        }
    }

    // MARK: - peers

    private func cmdPeers(home: PeerHome, args: [String], json: JSONMode) throws {
        guard let sub = args.first else {
            throw CLIError.usage("peers requires a subcommand: list")
        }
        let subArgs = Array(args.dropFirst())

        switch sub {
        case "list":
            try cmdPeersList(home: home, args: subArgs, json: json)
        default:
            throw CLIError.usage("Unknown peers subcommand: \(sub)")
        }
    }

    private func cmdPeersList(home: PeerHome, args: [String], json: JSONMode) throws {
        let parsed = try parseKeyValues(args)

        let limit = Int(parsed["--limit"] ?? "100") ?? 100
        let staleAfter = Int64(parsed["--stale-after"] ?? "86400") ?? 86400
        let includeStale = parsed["--include-stale"] != nil

        let store = try AethosStore(path: home.storeSQLitePath)
        let nowEpoch = AethosStore.epochSeconds(Date())

        let peers = try store.listPeers(
            limit: limit,
            sort: .lastSeenDesc,
            includeStale: includeStale,
            staleAfterSeconds: staleAfter,
            now: nowEpoch
        )

        let (total, stale) = try store.countPeers(
            staleAfterSeconds: staleAfter,
            now: nowEpoch
        )

        if json != .none {
            if json == .contractV1 {
                print(jsonString(CLIContractV1.peersList(
                    peers: peers,
                    summaryTotal: total,
                    summaryStale: stale,
                    nowEpochSeconds: nowEpoch,
                    staleAfterSeconds: staleAfter
                )))
            } else {
                let arr: [[String: Any]] = peers.map { p in
                    var d: [String: Any] = [
                        "wayfarer_id": p.wayfarerId,
                        "short_id": p.shortId,
                        "first_seen_at": p.firstSeenAt,
                        "last_seen_at": p.lastSeenAt,
                    ]
                    if let lea = p.lastExchangeAt {
                        d["last_exchange_at"] = lea
                    }
                    return d
                }
                let obj: [String: Any] = [
                    "peers": arr,
                    "summary": [
                        "total": total,
                        "stale": stale,
                    ] as [String: Any],
                ]
                print(jsonString(obj))
            }
        } else {
            if peers.isEmpty {
                print("No peers observed.")
            } else {
                for p in peers {
                    var line = "\(p.shortId)  last_seen=\(p.lastSeenAt)"
                    if let lea = p.lastExchangeAt {
                        line += "  last_exchange=\(lea)"
                    }
                    line += "  first_seen=\(p.firstSeenAt)"
                    print(line)
                }
            }
        }
    }

    // MARK: - relay

    private func cmdRelay(home: PeerHome, args: [String], json: JSONMode) throws {
        guard let sub = args.first else {
            throw CLIError.usage("relay requires a subcommand: list")
        }
        let subArgs = Array(args.dropFirst())

        switch sub {
        case "list":
            try cmdRelayList(home: home, args: subArgs, json: json)
        default:
            throw CLIError.usage("Unknown relay subcommand: \(sub)")
        }
    }

    // MARK: - messages

    private func cmdMessages(home: PeerHome, args: [String], json: JSONMode) throws {
        guard let sub = args.first else {
            throw CLIError.usage("messages requires a subcommand: list | show")
        }
        let subArgs = Array(args.dropFirst())
        switch sub {
        case "list":
            try cmdMessagesList(home: home, args: subArgs, json: json)
        case "show":
            try cmdMessagesShow(home: home, args: subArgs, json: json)
        default:
            throw CLIError.usage("Unknown messages subcommand: \(sub)")
        }
    }

    private func cmdMessagesList(home: PeerHome, args: [String], json: JSONMode) throws {
        let parsed = try parseKeyValues(args)
        let limit = Int(parsed["--limit"] ?? "50")
        guard let limit, limit > 0 else {
            throw CLIError.usage("messages list: --limit must be > 0")
        }
        let store = try AethosStore(path: home.storeSQLitePath)
        let rows = try store.listMessages(limit: limit)

        if json != .none {
            let messages: [[String: Any]] = rows.map { row in
                [
                    "message_id": row.messageId.hexString,
                    "kind": row.kind,
                    "direction": row.direction.rawValue,
                    "peer_from": row.peerFrom ?? NSNull(),
                    "peer_to": row.peerTo ?? NSNull(),
                    "created_at": iso8601(row.createdAt),
                ]
            }
            if json == .contractV1 {
                print(jsonString(CLIContractV1.messagesList(messages)))
            } else {
                print(jsonString(["messages": messages]))
            }
        } else {
            if rows.isEmpty {
                print("No messages.")
                return
            }
            for r in rows {
                print("\(r.messageId.hexString)  \(r.direction.rawValue)  kind=\(r.kind)  created_at=\(iso8601(r.createdAt))")
            }
        }
    }

    private func cmdMessagesShow(home: PeerHome, args: [String], json: JSONMode) throws {
        guard let hex = args.first, !hex.isEmpty else {
            throw CLIError.usage("messages show requires <message_id_hex>")
        }
        guard let id = Hex.decode(hex) else {
            throw CLIError.usage("messages show: invalid hex id")
        }
        let store = try AethosStore(path: home.storeSQLitePath)
        guard let row = try store.getMessage(id: id) else {
            throw CLIError.usage("Message not found: \(hex)")
        }

        let decodedBody: String
        if row.kind == "message.v1" {
            if let m = try? CanonicalEncoderV1.decodeMessage(canonical: row.canonical),
               let s = String(data: m.body, encoding: .utf8) {
                decodedBody = s
            } else {
                decodedBody = ""
            }
        } else {
            decodedBody = ""
        }

        let messageObj: [String: Any] = [
            "message_id": row.messageId.hexString,
            "kind": row.kind,
            "direction": row.direction.rawValue,
            "peer_from": row.peerFrom ?? NSNull(),
            "peer_to": row.peerTo ?? NSNull(),
            "created_at": iso8601(row.createdAt),
            "canonical_hex": row.canonical.hexString,
            "body_utf8": decodedBody.isEmpty ? NSNull() : decodedBody,
        ]

        if json != .none {
            if json == .contractV1 {
                print(jsonString(CLIContractV1.messagesShow(messageObj)))
            } else {
                print(jsonString(["message": messageObj]))
            }
        } else {
            print("message_id:  \(row.messageId.hexString)")
            print("kind:        \(row.kind)")
            print("direction:   \(row.direction.rawValue)")
            print("peer_from:   \(row.peerFrom ?? "")")
            print("peer_to:     \(row.peerTo ?? "")")
            print("created_at:  \(iso8601(row.createdAt))")
            print("canonical:   \(row.canonical.hexString)")
            if decodedBody.isEmpty {
                print("body_utf8:   ")
            } else {
                print("body_utf8:   \(decodedBody)")
            }
        }
    }

    private func cmdRelayList(home: PeerHome, args: [String], json: JSONMode) throws {
        guard args.isEmpty else {
            throw CLIError.usage("relay list takes no positional args")
        }

        let store = try AethosStore(path: home.storeSQLitePath)
        let now = Date()
        let transfers = try store.listRelayTransfers(activeOnly: true, now: now)

        if json != .none {
            if json == .contractV1 {
                print(jsonString(CLIContractV1.relayList(transfers)))
            } else {
                let arr = transfers.map { transferToDict($0) }
                let obj: [String: Any] = [
                    "relay_transfers": arr,
                    "count": transfers.count,
                ]
                print(jsonString(obj))
            }
        } else {
            if transfers.isEmpty {
                print("No active relay transfers.")
            } else {
                print("Relay transfers (\(transfers.count) active):")
                for t in transfers {
                    let progress = "parts_received=\(t.partsReceived)/\(t.partsTotal) bytes_received=\(t.bytesReceived)/\(t.bytesTotal)"
                    var line = "  \(t.transferId)  \(t.status.rawValue)  peer_to=\(t.peerTo)  \(progress)"
                    if let h = t.manifestHash { line += "  manifest=\(h)" }
                    if let f = t.originalFilename { line += "  file=\(f)" }
                    print(line)
                }
            }
        }
    }

    // MARK: - Pull replay

    /// Re-enqueue manifest, envelope, and chunks for a given manifest hash.
    /// Does not create new transfer rows — reuses existing store records.
    private func replayManifestContent(manifestHash: String, store: AethosStore, home: PeerHome, fm: FileManager) throws {
        // Look up existing transfers for this manifest hash
        let transfers = try store.lookupTransfersByManifestHashes([manifestHash])
        guard !transfers.isEmpty else { return }

        let now = Date()

        // Find manifest canonical bytes — try the manifest cache on disk first
        let manifestCachePath = home.transportManifestCacheDir.appendingPathComponent("\(manifestHash).bin")
        var manifestBytes: Data?
        if fm.fileExists(atPath: manifestCachePath.path) {
            manifestBytes = try? Data(contentsOf: manifestCachePath)
        }

        // Also check the outbox for a previously-enqueued manifest
        if manifestBytes == nil {
            let outboxItems = try store.peekQueuedOutbox(limit: 10_000)
            for item in outboxItems where item.kind == .manifest {
                let mId = AethosIDs.manifestId(canonicalBytes: item.payload)
                if Hex.encode(mId) == manifestHash {
                    manifestBytes = item.payload
                    break
                }
            }
        }

        // Also check the inbox for a previously received manifest
        if manifestBytes == nil {
            let inboxItems = try store.listInboxByKind(.manifest)
            for item in inboxItems {
                if Hex.encode(item.id) == manifestHash {
                    manifestBytes = item.payload
                    break
                }
            }
        }

        guard let manifestBytes else { return }

        let manifestId = AethosIDs.manifestId(canonicalBytes: manifestBytes)

        // Re-enqueue manifest
        try store.enqueue(item: OutboxItem(
            id: manifestId,
            kind: .manifest,
            payload: manifestBytes,
            enqueuedAt: now
        ))

        // Re-enqueue envelope if we have it
        let envelopes = try store.listInboxByKind(.envelope)
        for envItem in envelopes {
            if let envInfo = try? parseEnvelopeCanonical(envItem.payload) {
                if envInfo.manifestId == manifestId {
                    let envelopeId = AethosIDs.envelopeId(canonicalBytes: envItem.payload)
                    try store.enqueue(item: OutboxItem(
                        id: envelopeId,
                        kind: .envelope,
                        payload: envItem.payload,
                        enqueuedAt: now
                    ))
                    break
                }
            }
        }

        // Re-enqueue chunks from the store
        let (_, chunkIds) = try parseManifestCanonical(manifestBytes)
        for chunkId in chunkIds {
            if let chunkBytes = try store.getChunk(id: chunkId) {
                // Chunks go into outbox by being available via the router;
                // they're already in the chunk store. The manifest in the outbox
                // will cause the router to plan chunk sends.
                _ = chunkBytes // chunks are picked up by router via manifest
            }
        }
    }

    // MARK: - Relay detection

    private struct RelayDetection {
        let destHex: String
    }

    /// Check inbox envelopes for one that references the given manifestId.
    /// If found and its toWayfarerId differs from our local wayfarer, return the destination.
    private func detectRelayFromEnvelopes(
        manifestId: Data, store: AethosStore, localWayfarerHex: String
    ) throws -> RelayDetection? {
        let envelopes = try store.listInboxByKind(.envelope)
        for item in envelopes {
            if let env = try? parseEnvelopeCanonical(item.payload) {
                if env.manifestId == manifestId {
                    let destHex = Hex.encode(env.toWayfarerId)
                    if destHex != localWayfarerHex {
                        return RelayDetection(destHex: destHex)
                    }
                    return nil
                }
            }
        }
        return nil
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

            // Skip reassembly for relay custody transfers — relay nodes never
            // write the final payload to disk.
            let manifestIdDataPre = AethosIDs.manifestId(canonicalBytes: manifestBytes)
            let manifestHashHexPre = manifestIdDataPre.hexString
            if let transfer = try store.getTransferByManifestHash(manifestHashHexPre, direction: .inbound),
               transfer.custody == .relay {
                continue
            }

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
                        transfer.completedAt = Date()
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

    // MARK: - HTTP transport

    private func cmdServe(home: PeerHome, args: [String]) throws {
        let parsed = try parseKeyValues(args)
        guard let bind = parsed["--bind"], !bind.isEmpty else {
            throw CLIError.usage("serve requires --bind <host:port>")
        }

        let (host, port) = try parseBind(bind)
        try home.createDirectories()

        let identityStore = DefaultIdentityStore(directory: home.identityDir)
        let identityManager = IdentityManager(store: identityStore)
        let identity = try identityManager.loadOrCreate()

        let server = try HttpFrameServer(
            bindHost: host,
            port: port,
            inboxDir: home.transportInboxDir,
            outboxDir: home.transportOutboxDir,
            archiveDir: home.transportArchiveDir,
            localWayfarerIdHex: identity.wayfarerId.hexString
        )

        try server.start()
        FileHandle.standardError.write(Data("warning: serving over HTTP (no TLS); identity is verified at protocol layer\n".utf8))
        print("serve")
        print("  bind=\(host):\(port)")
        print("  wayfarerId=\(identity.wayfarerId.hexString)")
        print("  inbox=\(home.transportInboxDir.path)")
        print("  outbox=\(home.transportOutboxDir.path)")
        print("  archive=\(home.transportArchiveDir.path)")
        RunLoop.current.run()
    }

    private func cmdHttp(home: PeerHome, args: [String], json: JSONMode) throws {
        guard let sub = args.first else {
            throw CLIError.usage("http requires a subcommand: exchange")
        }
        let rest = Array(args.dropFirst())
        switch sub {
        case "exchange":
            try cmdHttpExchange(home: home, args: rest, json: json)
        default:
            throw CLIError.usage("Unknown http subcommand: \(sub)")
        }
    }

    // MARK: - remote transport

    private func cmdRemote(home: PeerHome, args: [String], json: JSONMode) throws {
        guard let sub = args.first else {
            throw CLIError.usage("remote requires a subcommand: push | exchange")
        }
        let rest = Array(args.dropFirst())
        switch sub {
        case "push":
            try cmdRemotePush(home: home, args: rest, json: json)
        case "exchange":
            try cmdRemoteExchange(home: home, args: rest, json: json)
        default:
            throw CLIError.usage("Unknown remote subcommand: \(sub)")
        }
    }

    private func cmdRemotePush(home: PeerHome, args: [String], json: JSONMode) throws {
        let parsed = try parseKeyValues(args)
        guard let urlStr = parsed["--to"], let base = URL(string: urlStr) else {
            throw CLIError.usage("remote push requires --to <http(s)://host:port>")
        }
        if base.scheme == "http" {
            FileHandle.standardError.write(Data("warning: using HTTP (no TLS); identity is verified at protocol layer\n".utf8))
        }

        let limit = Int(parsed["--limit"] ?? "500") ?? 500
        let requestCap = Int(parsed["--request-cap"] ?? "200") ?? 200

        try home.createDirectories()
        let store = try AethosStore(path: home.storeSQLitePath)

        let identityStore = DefaultIdentityStore(directory: home.identityDir)
        let identityManager = IdentityManager(store: identityStore)
        let identity = try identityManager.loadOrCreate()
        let localHex = identity.wayfarerId.hexString

        let http = try HttpLink(baseURL: base, localWayfarerIdHex: localHex, expectedRemoteWayfarerIdHex: nil)

        // Ensure we advertise current inventory for the remote to diff against.
        let now = Date()
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let advertiseHashes = try store.listAdvertisableManifestHashes(limit: limit, now: now)
        let inventory = InventoryV1(manifests: advertiseHashes, generatedAtUnixMs: nowMs)
        let inventoryCanonical = CanonicalEncoderV1.encode(inventory)
        let inventoryId = AethosIDs.sha256(inventoryCanonical)
        try store.enqueue(item: OutboxItem(id: inventoryId, kind: .inventory, payload: inventoryCanonical, enqueuedAt: now))

        let sent = try httpPumpAndSend(home: home, store: store, http: http)

        if json != .none {
            if json == .contractV1 {
                print(jsonString(CLIContractV1.remotePush(
                    to: base.absoluteString,
                    advertisedCount: advertiseHashes.count,
                    framesSent: sent,
                    requestCap: requestCap
                )))
            } else {
                print(jsonString([
                    "remote_push": [
                        "advertised_count": advertiseHashes.count,
                        "frames_sent": sent,
                        "request_cap": requestCap,
                    ] as [String: Any]
                ]))
            }
        } else {
            print("remote push")
            print("  to=\(base.absoluteString)")
            print("  advertised_count=\(advertiseHashes.count)")
            print("  frames_sent=\(sent)")
        }
    }

    private func cmdRemoteExchange(home: PeerHome, args: [String], json: JSONMode) throws {
        let parsed = try parseKeyValues(args)
        guard let urlStr = parsed["--with"], let base = URL(string: urlStr) else {
            throw CLIError.usage("remote exchange requires --with <http(s)://host:port>")
        }
        if base.scheme == "http" {
            FileHandle.standardError.write(Data("warning: using HTTP (no TLS); identity is verified at protocol layer\n".utf8))
        }

        // Delegate to existing implementation for now.
        var forwarded: [String] = []
        forwarded.append("--url")
        forwarded.append(urlStr)
        if let peer = parsed["--peer"], !peer.isEmpty {
            forwarded.append("--peer")
            forwarded.append(peer)
        }
        if let rounds = parsed["--rounds"], !rounds.isEmpty {
            forwarded.append("--rounds")
            forwarded.append(rounds)
        }
        if let limit = parsed["--limit"], !limit.isEmpty {
            forwarded.append("--limit")
            forwarded.append(limit)
        }
        if let cap = parsed["--request-cap"], !cap.isEmpty {
            forwarded.append("--request-cap")
            forwarded.append(cap)
        }
        try cmdHttpExchange(home: home, args: forwarded, json: json)
    }

    private func cmdHttpExchange(home: PeerHome, args: [String], json: JSONMode) throws {
        let parsed = try parseKeyValues(args)
        guard let urlStr = parsed["--url"], let base = URL(string: urlStr) else {
            throw CLIError.usage("http exchange requires --url <http(s)://host:port>")
        }
        let rounds = Int(parsed["--rounds"] ?? "5") ?? 5
        guard rounds > 0 else { throw CLIError.usage("--rounds must be > 0") }

        let limit = Int(parsed["--limit"] ?? "500") ?? 500
        let requestCap = Int(parsed["--request-cap"] ?? "200") ?? 200

        try home.createDirectories()
        let store = try AethosStore(path: home.storeSQLitePath)

        let identityStore = DefaultIdentityStore(directory: home.identityDir)
        let identityManager = IdentityManager(store: identityStore)
        let identity = try identityManager.loadOrCreate()
        let localHex = identity.wayfarerId.hexString

        let expectedRemote: String? = parsed["--peer"]
        let http = try HttpLink(baseURL: base, localWayfarerIdHex: localHex, expectedRemoteWayfarerIdHex: expectedRemote)

        var remoteHex: String? = nil
        var totalPulled = 0
        var totalSent = 0

        for _ in 0..<rounds {
            let pulled = try httpPullIntoInbox(home: home, http: http)
            totalPulled += pulled.frames.count
            if remoteHex == nil {
                remoteHex = pulled.remoteWayfarerIdHex
            }

            guard let remote = remoteHex ?? expectedRemote else {
                // Try to discover remote identity without consuming a frame.
                let (_, r) = try http.receiveWithRemoteInfo()
                remoteHex = r
                if remoteHex == nil {
                    throw CLIError.usage("Remote did not provide X-Aethos-From-WayfarerId; start remote with 'aethos serve'")
                }
                continue
            }

            // Run one exchange round using the same logic as inventory gossip/exchange.
            _ = try performExchange(home: home, store: store, peerWayfarerHex: remote, limit: limit, requestCap: requestCap)

            // Send planned frames over HTTP.
            let sent = try httpPumpAndSend(home: home, store: store, http: http)
            totalSent += sent
        }

        if json != .none {
            if json == .contractV1 {
                print(jsonString(CLIContractV1.httpExchange(
                    url: base.absoluteString,
                    rounds: rounds,
                    remoteWayfarerId: remoteHex ?? "",
                    framesPulled: totalPulled,
                    framesSent: totalSent,
                    limit: limit,
                    requestCap: requestCap
                )))
            } else {
                let obj: [String: Any] = [
                    "http_exchange": [
                        "rounds": rounds,
                        "remote_wayfarer_id": remoteHex ?? "",
                        "frames_pulled": totalPulled,
                        "frames_sent": totalSent,
                    ] as [String: Any]
                ]
                print(jsonString(obj))
            }
        } else {
            print("http exchange")
            print("  rounds=\(rounds)")
            print("  remote_wayfarer_id=\(remoteHex ?? "")")
            print("  frames_pulled=\(totalPulled)")
            print("  frames_sent=\(totalSent)")
        }
    }

    private func httpPullIntoInbox(home: PeerHome, http: HttpLink) throws -> (frames: [Frame], remoteWayfarerIdHex: String?) {
        var frames: [Frame] = []
        var remoteHex: String? = nil
        let fm = FileManager.default

        for _ in 0..<2_000 {
            let (f, remote) = try http.receiveWithRemoteInfo()
            if remoteHex == nil { remoteHex = remote }
            guard let f else { break }
            frames.append(f)

            let name = "http-in-\(UUID().uuidString).bin"
            let url = home.transportInboxDir.appendingPathComponent(name, isDirectory: false)
            try f.encode().write(to: url, options: [.atomic])
        }

        // Ensure inbox dir exists.
        if !fm.fileExists(atPath: home.transportInboxDir.path) {
            try fm.createDirectory(at: home.transportInboxDir, withIntermediateDirectories: true)
        }

        return (frames, remoteHex)
    }

    private func httpPumpAndSend(home: PeerHome, store: AethosStore, http: HttpLink) throws -> Int {
        let router = Router(store: store)
        let plan = try router.planNextSession(budget: SessionBudget(maxBytes: 64 * 1024, maxItems: 256), now: Date())

        var framesSent = 0
        var remainingBytes = 64 * 1024
        let maxFramePayloadBytes = 1024

        for item in plan {
            let frames = try CargoCodec.encode(item, maxFramePayloadBytes: maxFramePayloadBytes)
            for f in frames {
                if f.sizeBytes > remainingBytes { return framesSent }
                try http.send(f)
                remainingBytes -= f.sizeBytes
                framesSent += 1
            }
        }
        return framesSent
    }

    private func parseBind(_ bind: String) throws -> (String, UInt16) {
        // host:port
        let comps = bind.split(separator: ":")
        guard comps.count == 2, let p = UInt16(comps[1]) else {
            throw CLIError.usage("--bind must be in host:port form")
        }
        return (String(comps[0]), p)
    }

    // MARK: - Arg parsing

    /// Boolean flags that take no value argument.
    private static let booleanFlags: Set<String> = ["--include-stale", "--json", "--json-v1"]

    private func parseKeyValues(_ args: [String]) throws -> [String: String] {
        var out: [String: String] = [:]
        var i = 0
        while i < args.count {
            let k = args[i]
            if k.hasPrefix("--") {
                if Self.booleanFlags.contains(k) {
                    out[k] = "true"
                    i += 1
                } else {
                    guard i + 1 < args.count else {
                        throw CLIError.usage("Missing value for \(k)")
                    }
                    out[k] = args[i + 1]
                    i += 2
                }
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
            "custody": t.custody.rawValue,
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
            "evicted": t.evicted,
        ]
        if let v = t.originalFilename { d["original_filename"] = v }
        if let v = t.manifestHash { d["manifest_hash"] = v }
        if let v = t.payloadHash { d["payload_hash"] = v }
        if let v = t.lastError { d["last_error"] = v }
        if let v = t.ttlSeconds { d["ttl_seconds"] = v }
        if let v = t.expiresAt { d["expires_at"] = iso8601(v) }
        if let v = t.completedAt { d["completed_at"] = iso8601(v) }
        return d
    }

    private func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    private func jsonString(_ obj: [String: Any]) -> String {
        return CLIJSON.serializeJSON(obj, indent: 0)
    }

    // MARK: - Usage

    static let usage = """
    Usage:
      aethos <command> [--home <path>] [options]

    Commands:
      init                  Initialize peer home (dirs, store, identity)
      status                Show peer home, identity, and paths
      send                  Queue a file for delivery (file -> chunks + manifest/envelope)
      ingest                Read frames from inbox and store them
      pump                  Plan + write frames to outbox
      serve                 Run HTTP frame server (POST/GET /frame)
      http exchange         Inventory exchange over HTTP
      remote push           Push planned frames to a remote peer
      remote exchange       Inventory exchange over HTTP (alias)
      messages list         List stored protocol messages
      messages show         Show a stored protocol message
      transfers list        List all transfers
      transfers show        Show details for a transfer
      inventory advertise   Advertise local manifest inventory to outbox
      inventory request     Read remote inventory from stdin, enqueue pull requests
      inventory exchange    One inventory exchange round with a peer
      inventory gossip      Gossip inventory across known peers
      peers list            List known peers
      relay list            List active relay custody transfers

    Global options:
      --home <path>    Peer home directory (default: ./peer)
      --json           Output in JSON format (status, transfers, inventory, relay, peers)
      --json-v1        Output stable JSON Contract v1

    Command options:
      send   --file <path> --to <wayfarerIdHex>
      ingest --max <n>
      pump   --max-bytes <n> --max-items <n>
      serve  --bind <host:port>
      http exchange --url <http(s)://host:port> [--peer <wayfarerIdHex>] [--rounds <n>]
                   [--limit <n>] [--request-cap <n>]
      remote push --to <http(s)://host:port> [--limit <n>] [--request-cap <n>]
      remote exchange --with <http(s)://host:port> [--peer <wayfarerIdHex>] [--rounds <n>]
                    [--limit <n>] [--request-cap <n>]
      transfers show <transfer_id>
      inventory request     (reads inventory JSON from stdin)
      inventory exchange    --with <wayfarerIdHex> [--limit <n>] [--request-cap <n>]
      inventory gossip      [--limit-peers <n>] [--peer-limit <n>] [--request-cap <n>]
                            [--stale-after <s>] [--max-rounds <n>] [--include-stale]
      peers list            [--limit <n>] [--stale-after <s>] [--include-stale]
      messages list         [--limit <n>]
      messages show <message_id_hex>
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
