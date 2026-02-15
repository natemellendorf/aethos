#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
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

/// V2 on-disk format: includes metadata alongside key material.
/// Migration choice: Option A — adopt the derived wayfarerId from the keypair.
/// Since v1 already derived wayfarerId = SHA-256(signingPublicKey), the migration
/// is lossless: the same keypair produces the same wayfarerId. We write separate
/// key files (private.key, public.key) and a metadata file (identity-v2.json).
public struct IdentityStoreSnapshotV2: Codable, Equatable, Sendable {
    public let version: Int
    public let keyType: String
    public let createdAt: String
    public let signingPublicKeyHex: String
    public let exchangePublicKeyHex: String
    /// The legacy wayfarer ID (hex) from v1, if this identity was migrated.
    /// Always matches the derived ID since v1 already used SHA-256(signingPub).
    public let legacyWayfarerId: String?

    public init(
        keyType: String,
        createdAt: String,
        signingPublicKeyHex: String,
        exchangePublicKeyHex: String,
        legacyWayfarerId: String? = nil
    ) {
        self.version = 2
        self.keyType = keyType
        self.createdAt = createdAt
        self.signingPublicKeyHex = signingPublicKeyHex
        self.exchangePublicKeyHex = exchangePublicKeyHex
        self.legacyWayfarerId = legacyWayfarerId
    }
}

public struct DefaultIdentityStore: IdentityStore {
    public let directory: URL
    private let v1FileURL: URL
    private let v2FileURL: URL
    private let privateKeyURL: URL
    private let publicKeyURL: URL

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            self.directory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".aethos-dev/identity", isDirectory: true)
        }
        self.v1FileURL = self.directory.appendingPathComponent("identity-v1.json", isDirectory: false)
        self.v2FileURL = self.directory.appendingPathComponent("identity-v2.json", isDirectory: false)
        self.privateKeyURL = self.directory.appendingPathComponent("private.key", isDirectory: false)
        self.publicKeyURL = self.directory.appendingPathComponent("public.key", isDirectory: false)
    }

    public func load() throws -> IdentityStoreSnapshot? {
        let fm = FileManager.default

        // Prefer v2 format if it exists
        if fm.fileExists(atPath: v2FileURL.path) && fm.fileExists(atPath: privateKeyURL.path) {
            let privData = try Data(contentsOf: privateKeyURL)
            // private.key layout: [32 bytes signingPrivKey][32 bytes exchangePrivKey]
            guard privData.count == 64 else { return nil }
            let signingPriv = privData.prefix(32)
            let exchangePriv = privData.suffix(32)
            return IdentityStoreSnapshot(
                signingPrivateKeyRaw: Data(signingPriv),
                exchangePrivateKeyRaw: Data(exchangePriv)
            )
        }

        // Fall back to v1
        guard fm.fileExists(atPath: v1FileURL.path) else { return nil }
        let data = try Data(contentsOf: v1FileURL)
        let snapshot = try JSONDecoder().decode(IdentityStoreSnapshot.self, from: data)

        // Migrate v1 -> v2 on load
        try migrateV1toV2(snapshot: snapshot)

        return snapshot
    }

    public func save(_ snapshot: IdentityStoreSnapshot) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        // Write v1 for backward compatibility
        let v1Data = try JSONEncoder().encode(snapshot)
        try v1Data.write(to: v1FileURL, options: [.atomic])

        // Write v2 files
        try writeV2Files(snapshot: snapshot, legacyWayfarerId: nil)

        // Tighten permissions
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: v1FileURL.path)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: v2FileURL.path)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateKeyURL.path)
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: publicKeyURL.path)
    }

    /// Check whether the v2 format files exist.
    public var hasV2Format: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: v2FileURL.path) && fm.fileExists(atPath: privateKeyURL.path)
    }

    /// Load the v2 metadata if it exists.
    public func loadV2Metadata() throws -> IdentityStoreSnapshotV2? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: v2FileURL.path) else { return nil }
        let data = try Data(contentsOf: v2FileURL)
        return try JSONDecoder().decode(IdentityStoreSnapshotV2.self, from: data)
    }

    /// Check file permissions on the private key (best-effort).
    public func privateKeyPermissions() -> Int? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: privateKeyURL.path),
              let perms = attrs[.posixPermissions] as? Int else {
            return nil
        }
        return perms
    }

    // MARK: - Migration

    private func migrateV1toV2(snapshot: IdentityStoreSnapshot) throws {
        let fm = FileManager.default

        // Skip if already migrated
        guard !fm.fileExists(atPath: v2FileURL.path) else { return }

        // Compute wayfarerId from v1 keys to record as legacy
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *) {
            let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: snapshot.signingPrivateKeyRaw)
            let wayfarerId = AethosIDs.sha256(signingKey.publicKey.rawRepresentation)
            let legacyWayfarerIdHex = Hex.encode(wayfarerId)
            try writeV2Files(snapshot: snapshot, legacyWayfarerId: legacyWayfarerIdHex)

            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: v2FileURL.path)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateKeyURL.path)
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: publicKeyURL.path)
        }
    }

    private func writeV2Files(snapshot: IdentityStoreSnapshot, legacyWayfarerId: String?) throws {
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *) {
            let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: snapshot.signingPrivateKeyRaw)
            let exchangeKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: snapshot.exchangePrivateKeyRaw)

            let signingPub = signingKey.publicKey.rawRepresentation
            let exchangePub = exchangeKey.publicKey.rawRepresentation

            let now = ISO8601DateFormatter().string(from: Date())
            let v2Meta = IdentityStoreSnapshotV2(
                keyType: IdentityV1.keyType,
                createdAt: now,
                signingPublicKeyHex: Hex.encode(signingPub),
                exchangePublicKeyHex: Hex.encode(exchangePub),
                legacyWayfarerId: legacyWayfarerId
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let v2Data = try encoder.encode(v2Meta)
            try v2Data.write(to: v2FileURL, options: [.atomic])

            // private.key: raw concatenation [signingPriv:32][exchangePriv:32]
            var privData = Data()
            privData.append(snapshot.signingPrivateKeyRaw)
            privData.append(snapshot.exchangePrivateKeyRaw)
            try privData.write(to: privateKeyURL, options: [.atomic])

            // public.key: raw concatenation [signingPub:32][exchangePub:32]
            var pubData = Data()
            pubData.append(signingPub)
            pubData.append(exchangePub)
            try pubData.write(to: publicKeyURL, options: [.atomic])
        }
    }
}
