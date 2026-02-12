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

        let (home, rest) = try parseHome(from: argv)
        switch command {
        case "init":
            try cmdInit(home: home, args: rest)
        case "status":
            try cmdStatus(home: home, args: rest)
        case "send":
            try cmdSend(home: home, args: rest)
        case "ingest":
            try cmdIngest(home: home, args: rest)
        case "pump":
            try cmdPump(home: home, args: rest)
        case "help", "--help", "-h":
            print(Self.usage)
        default:
            throw CLIError.usage("Unknown command: \(command)\n\n\(Self.usage)")
        }
    }

    private func parseHome(from args: [String]) throws -> (PeerHome, [String]) {
        var rest: [String] = []
        var i = 0
        var homeURL: URL? = nil

        while i < args.count {
            let a = args[i]
            if a == "--home" {
                guard i + 1 < args.count else { throw CLIError.usage("--home requires a path") }
                homeURL = URL(fileURLWithPath: args[i + 1])
                i += 2
                continue
            }
            rest.append(a)
            i += 1
        }

        return (PeerHome(root: homeURL ?? PeerHome.defaultRootURL()), rest)
    }

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

    private func cmdStatus(home: PeerHome, args: [String]) throws {
        guard args.isEmpty else {
            throw CLIError.usage("status takes no positional args")
        }

        let fm = FileManager.default
        let storeExists = fm.fileExists(atPath: home.storeSQLitePath.path)

        print("Peer home:\n  \(home.root.path)")
        print("Store:\n  \(home.storeSQLitePath.path) (exists: \(storeExists ? "yes" : "no"))")
        print("Transport dirs:\n  inbox=\(home.transportInboxDir.path)\n  outbox=\(home.transportOutboxDir.path)\n  archive=\(home.transportArchiveDir.path)")

        do {
            let identityStore = DefaultIdentityStore(directory: home.identityDir)
            let identityManager = IdentityManager(store: identityStore)
            let identity = try identityManager.loadOrCreate()
            print("Identity:\n  wayfarerId=\(identity.wayfarerId.hexString)\n  shortId=\(identity.shortId)")
        } catch {
            print("Identity:\n  not initialized (run: aethos init)")
        }
    }

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

        print("Queued send")
        print("  file=\(fileURL.path)")
        print("  bytes=\(data.count)")
        print("  chunks=\(chunks.count)")
        print("  manifestId=\(manifestId.hexString)")
        print("  envelopeId=\(envelopeId.hexString)")
    }

    private func cmdIngest(home: PeerHome, args: [String]) throws {
        let parsed = try parseKeyValues(args)
        let ingestMax = Int(parsed["--max"] ?? "100")
        guard let ingestMax, ingestMax > 0 else { throw CLIError.usage("--max must be > 0") }

        try home.createDirectories()
        let store = try AethosStore(path: home.storeSQLitePath)
        let link = try FileDropLink(inboxDir: home.transportInboxDir, outboxDir: home.transportOutboxDir, archiveDir: home.transportArchiveDir)

        let fm = FileManager.default
        let beforeBad = countBadFiles(in: home.transportArchiveDir, fileManager: fm)

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
                case .envelope:
                    try store.recordReceived(item: InboxItem(id: id, kind: .envelope, payload: bytes, receivedAt: Date()))
                    storedItems += 1
                case .manifest:
                    try store.recordReceived(item: InboxItem(id: id, kind: .manifest, payload: bytes, receivedAt: Date()))
                    storedItems += 1

                    // Cache manifest canonical bytes for later reassembly.
                    let manifestPath = home.transportManifestCacheDir.appendingPathComponent("\(Hex.encode(id)).bin")
                    if !fm.fileExists(atPath: manifestPath.path) {
                        try bytes.write(to: manifestPath, options: [.atomic])
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
            }
        }

        try saveSendCursors(cursor, to: home.transportCursorPath)

        print("pump")
        print("  plannedItems=\(plan.count)")
        print("  framesSent=\(sentFrames)")
        print("  bytesSent=\(sentBytes)")
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

            let rebuilt = try Chunking.reassemble(chunksById: chunksById, manifest: manifest)
            let outName = "reassembled-\(AethosIDs.manifestId(canonicalBytes: manifestBytes).hexString).bin"
            let outURL = home.transportArchiveDir.appendingPathComponent(outName, isDirectory: false)
            if !fm.fileExists(atPath: outURL.path) {
                try rebuilt.write(to: outURL, options: [.atomic])
                deliveredCount += 1
            }
        }

        return deliveredCount
    }

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

    static let usage = """
    Usage:
      aethos <command> [--home <path>] [options]

    Commands:
      init        Initialize peer home (dirs, store, identity)
      status      Show peer home, identity, and paths
      send        Queue a file for delivery (file -> chunks + manifest/envelope)
      ingest      Read frames from inbox and store them
      pump        Plan + write frames to outbox

    Global options:
      --home <path>    Peer home directory (default: ./peer)

    Command options:
      send   --file <path> --to <wayfarerIdHex>
      ingest --max <n>
      pump   --max-bytes <n> --max-items <n>
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
