import Foundation

public protocol IdentityStore: Sendable {
    func load() throws -> IdentityStoreSnapshot?
    func save(_ snapshot: IdentityStoreSnapshot) throws
}

public struct IdentityStoreSnapshot: Codable, Equatable, Sendable {
    public let signingPrivateKeyRaw: Data
    public let exchangePrivateKeyRaw: Data

    public init(signingPrivateKeyRaw: Data, exchangePrivateKeyRaw: Data) {
        self.signingPrivateKeyRaw = signingPrivateKeyRaw
        self.exchangePrivateKeyRaw = exchangePrivateKeyRaw
    }
}

public struct DefaultIdentityStore: IdentityStore {
    public let directory: URL
    private let fileURL: URL

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            self.directory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".aethos-dev/identity", isDirectory: true)
        }
        self.fileURL = self.directory.appendingPathComponent("identity-v1.json", isDirectory: false)
    }

    public func load() throws -> IdentityStoreSnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(IdentityStoreSnapshot.self, from: data)
    }

    public func save(_ snapshot: IdentityStoreSnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: fileURL, options: [.atomic])

        // Best-effort: tighten permissions (ignore if platform/filesystem doesn't support).
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
