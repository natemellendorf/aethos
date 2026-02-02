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
        _ = home

        guard let file = parsed["--file"], !file.isEmpty else {
            throw CLIError.usage("send requires --file <path>")
        }
        guard let to = parsed["--to"], !to.isEmpty else {
            throw CLIError.usage("send requires --to <wayfarerId-hex>")
        }

        guard Hex.decode(to) != nil else {
            throw CLIError.usage("--to must be hex")
        }
        let fileURL = URL(fileURLWithPath: file)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw CLIError.usage("--file not found: \(file)")
        }

        print("send not implemented yet")
    }

    private func cmdIngest(home: PeerHome, args: [String]) throws {
        let parsed = try parseKeyValues(args)
        _ = home

        guard let input = parsed["--input"], !input.isEmpty else {
            throw CLIError.usage("ingest requires --input <path>")
        }
        let url = URL(fileURLWithPath: input)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError.usage("--input not found: \(input)")
        }
        print("ingest not implemented yet")
    }

    private func cmdPump(home: PeerHome, args: [String]) throws {
        let parsed = try parseKeyValues(args)
        _ = home

        if let bytes = parsed["--budget-bytes"], Int(bytes) == nil {
            throw CLIError.usage("--budget-bytes must be an Int")
        }
        if let items = parsed["--budget-items"], Int(items) == nil {
            throw CLIError.usage("--budget-items must be an Int")
        }
        print("pump not implemented yet")
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
      send        Queue a send (stub)
      ingest      Ingest incoming frames/files (stub)
      pump        Run a budgeted pump cycle (stub)

    Global options:
      --home <path>    Peer home directory (default: ./peer)
    """
}

do {
    try CLI(args: CommandLine.arguments).run()
} catch let CLIError.usage(msg) {
    fputs("\(msg)\n", stderr)
    exit(2)
} catch {
    fputs("Error: \(error)\n", stderr)
    exit(1)
}
