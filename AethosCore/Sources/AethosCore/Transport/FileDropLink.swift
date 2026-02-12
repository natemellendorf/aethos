import Foundation

public final class FileDropLink: Link {
    public enum FileDropError: Swift.Error, Equatable {
        case cannotCreateDirectories(String)
        case cannotWrite(String)
        case cannotArchive(String)
        case cannotDecode(String)
    }

    public let inboxDir: URL
    public let outboxDir: URL
    public let archiveDir: URL

    private let fileManager: FileManager

    public init(
        inboxDir: URL,
        outboxDir: URL,
        archiveDir: URL,
        fileManager: FileManager = .default
    ) throws {
        self.inboxDir = inboxDir
        self.outboxDir = outboxDir
        self.archiveDir = archiveDir
        self.fileManager = fileManager

        do {
            try fileManager.createDirectory(at: inboxDir, withIntermediateDirectories: true, attributes: nil)
            try fileManager.createDirectory(at: outboxDir, withIntermediateDirectories: true, attributes: nil)
            try fileManager.createDirectory(at: archiveDir, withIntermediateDirectories: true, attributes: nil)
        } catch {
            throw FileDropError.cannotCreateDirectories("\(error)")
        }
    }

    public func send(_ frame: Frame) throws {
        let data = frame.encode()
        let name = Self.uniqueName(prefix: "out-", ext: "bin")
        let url = outboxDir.appendingPathComponent(name, isDirectory: false)

        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw FileDropError.cannotWrite("\(error)")
        }
    }

    public func receive() throws -> Frame? {
        while true {
            guard let next = try oldestInboxEntry() else {
                return nil
            }

            // Try to read file bytes.
            let bytes: Data
            do {
                bytes = try Data(contentsOf: next)
            } catch {
                // Bad/unreadable input: archive and continue.
                try archiveBad(next, reason: "read")
                continue
            }

            // Decode frame.
            let frame: Frame
            do {
                frame = try Frame.decode(bytes)
            } catch {
                try archiveBad(next, reason: "decode")
                continue
            }

            // Move to archive on successful decode.
            do {
                try archiveGood(next)
            } catch {
                throw FileDropError.cannotArchive("\(error)")
            }

            return frame
        }
    }

    // MARK: Inbox scanning

    private func oldestInboxEntry() throws -> URL? {
        let entries = try fileManager.contentsOfDirectory(
            at: inboxDir,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        let candidates = entries.filter { !$0.lastPathComponent.hasPrefix(".") }
        guard !candidates.isEmpty else { return nil }

        // Prefer determinism: sort by filename, then by modification date.
        let sorted = candidates.sorted { a, b in
            if a.lastPathComponent != b.lastPathComponent {
                return a.lastPathComponent < b.lastPathComponent
            }
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }

        return sorted.first
    }

    // MARK: Archiving

    private func archiveGood(_ url: URL) throws {
        var name = url.lastPathComponent
        // Rename processed inbound files so they don't match the outbound "out-*" pattern.
        if name.hasPrefix("out-") {
            name = "in-" + name.dropFirst(4)
        }
        let dest = archiveDir.appendingPathComponent(name, isDirectory: false)
        try moveItemReplacing(source: url, dest: dest)
    }

    private func archiveBad(_ url: URL, reason: String) throws {
        let base = url.lastPathComponent
        let name = base + "." + reason + ".bad"
        let dest = archiveDir.appendingPathComponent(name, isDirectory: false)
        do {
            try moveItemReplacing(source: url, dest: dest)
        } catch {
            throw FileDropError.cannotArchive("\(error)")
        }
    }

    private func moveItemReplacing(source: URL, dest: URL) throws {
        if fileManager.fileExists(atPath: dest.path) {
            try fileManager.removeItem(at: dest)
        }
        try fileManager.moveItem(at: source, to: dest)
    }

    // MARK: Naming

    private static func uniqueName(prefix: String, ext: String) -> String {
        // Sortable, reasonably unique: yyyyMMddHHmmssSSS + random.
        let now = Date()
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "yyyyMMddHHmmssSSS"
        let ts = fmt.string(from: now)
        let rand = UInt64.random(in: 0...UInt64.max)
        return "\(prefix)\(ts)-\(String(rand, radix: 16)).\(ext)"
    }
}
