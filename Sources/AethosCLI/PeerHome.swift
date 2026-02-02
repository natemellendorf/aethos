import Foundation

struct PeerHome {
    let root: URL

    var identityDir: URL { root.appendingPathComponent("identity", isDirectory: true) }
    var storeDir: URL { root.appendingPathComponent("store", isDirectory: true) }
    var storeSQLitePath: URL { storeDir.appendingPathComponent("aethos.sqlite", isDirectory: false) }

    var transportDir: URL { root.appendingPathComponent("transport", isDirectory: true) }
    var transportInboxDir: URL { transportDir.appendingPathComponent("inbox", isDirectory: true) }
    var transportOutboxDir: URL { transportDir.appendingPathComponent("outbox", isDirectory: true) }
    var transportArchiveDir: URL { transportDir.appendingPathComponent("archive", isDirectory: true) }

    init(root: URL) {
        self.root = root
    }

    static func defaultRootURL() -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("peer", isDirectory: true)
    }

    func createDirectories() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: nil)
        try fm.createDirectory(at: identityDir, withIntermediateDirectories: true, attributes: nil)
        try fm.createDirectory(at: storeDir, withIntermediateDirectories: true, attributes: nil)
        try fm.createDirectory(at: transportInboxDir, withIntermediateDirectories: true, attributes: nil)
        try fm.createDirectory(at: transportOutboxDir, withIntermediateDirectories: true, attributes: nil)
        try fm.createDirectory(at: transportArchiveDir, withIntermediateDirectories: true, attributes: nil)
    }
}
