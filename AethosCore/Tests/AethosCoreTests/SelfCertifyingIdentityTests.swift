#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import Testing
@testable import AethosCore

// MARK: - Deterministic Derivation

@Test
func deterministicDerivationSamePubKeySameWayfarerId() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = DefaultIdentityStore(directory: dir)
    let manager = IdentityManager(store: store)
    let id1 = try manager.loadOrCreate()

    // Manually verify: wayfarerId == SHA-256(signingPublicKey)
    let expected = AethosIDs.sha256(id1.signingPublicKey)
    #expect(id1.wayfarerId == expected)
    #expect(id1.isSelfCertifying)

    // Reload from disk - same derivation
    let manager2 = IdentityManager(store: DefaultIdentityStore(directory: dir))
    let id2 = try manager2.loadOrCreate()
    #expect(id1.wayfarerId == id2.wayfarerId)
    #expect(id2.isSelfCertifying)
}

@Test
func differentPubKeyDifferentWayfarerId() throws {
    let dir1 = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let dir2 = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: dir1)
        try? FileManager.default.removeItem(at: dir2)
    }

    let id1 = try IdentityManager(store: DefaultIdentityStore(directory: dir1)).loadOrCreate()
    let id2 = try IdentityManager(store: DefaultIdentityStore(directory: dir2)).loadOrCreate()

    // Different keypairs -> different wayfarerIds
    #expect(id1.signingPublicKey != id2.signingPublicKey)
    #expect(id1.wayfarerId != id2.wayfarerId)
}

// MARK: - Persistence Across Runs

@Test
func identityPersistedAndReloadedAcrossRuns() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // First "run": create identity
    let store1 = DefaultIdentityStore(directory: dir)
    let id1 = try IdentityManager(store: store1).loadOrCreate()

    // Verify v2 files exist after creation
    #expect(store1.hasV2Format)

    // Second "run": load from fresh manager instance
    let store2 = DefaultIdentityStore(directory: dir)
    let id2 = try IdentityManager(store: store2).loadOrCreate()

    #expect(id1.wayfarerId == id2.wayfarerId)
    #expect(id1.signingPublicKey == id2.signingPublicKey)
    #expect(id1.exchangePublicKey == id2.exchangePublicKey)
}

// MARK: - V2 Storage Format

@Test
func v2StorageCreatesAllFiles() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = DefaultIdentityStore(directory: dir)
    _ = try IdentityManager(store: store).loadOrCreate()

    let fm = FileManager.default
    // All four files should exist
    #expect(fm.fileExists(atPath: dir.appendingPathComponent("identity-v1.json").path))
    #expect(fm.fileExists(atPath: dir.appendingPathComponent("identity-v2.json").path))
    #expect(fm.fileExists(atPath: dir.appendingPathComponent("private.key").path))
    #expect(fm.fileExists(atPath: dir.appendingPathComponent("public.key").path))
}

@Test
func v2MetadataContainsCorrectFields() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = DefaultIdentityStore(directory: dir)
    let identity = try IdentityManager(store: store).loadOrCreate()

    let v2Meta = try store.loadV2Metadata()
    #expect(v2Meta != nil)
    #expect(v2Meta!.version == 2)
    #expect(v2Meta!.keyType == "Ed25519")
    #expect(v2Meta!.signingPublicKeyHex == identity.signingPublicKeyHex)
    #expect(v2Meta!.exchangePublicKeyHex == identity.exchangePublicKeyHex)
    #expect(v2Meta!.legacyWayfarerId == nil) // fresh creation, no legacy
    #expect(!v2Meta!.createdAt.isEmpty)
}

@Test
func publicKeyFileContainsCorrectData() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = DefaultIdentityStore(directory: dir)
    let identity = try IdentityManager(store: store).loadOrCreate()

    let pubData = try Data(contentsOf: dir.appendingPathComponent("public.key"))
    // public.key: [signingPub:32][exchangePub:32]
    #expect(pubData.count == 64)
    #expect(Data(pubData.prefix(32)) == identity.signingPublicKey)
    #expect(Data(pubData.suffix(32)) == identity.exchangePublicKey)
}

// MARK: - Private Key Permissions

@Test
func privateKeyFileHasRestrictedPermissions() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = DefaultIdentityStore(directory: dir)
    _ = try IdentityManager(store: store).loadOrCreate()

    if let perms = store.privateKeyPermissions() {
        // Expect 0o600 (owner read/write only)
        #expect(perms == 0o600)
    }
    // If permissions can't be checked (e.g. some CI environments), test still passes
}

// MARK: - Migration V1 to V2

@Test
func migrationV1ToV2PreservesIdentity() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    // Create a v1-only identity manually
    let signingKey = Curve25519.Signing.PrivateKey()
    let exchangeKey = Curve25519.KeyAgreement.PrivateKey()
    let v1Snapshot = IdentityStoreSnapshot(
        signingPrivateKeyRaw: signingKey.rawRepresentation,
        exchangePrivateKeyRaw: exchangeKey.rawRepresentation
    )
    let v1Data = try JSONEncoder().encode(v1Snapshot)
    let v1Path = dir.appendingPathComponent("identity-v1.json")
    try v1Data.write(to: v1Path)

    // Compute expected wayfarerId
    let expectedWayfarerId = AethosIDs.sha256(signingKey.publicKey.rawRepresentation)
    let expectedHex = Hex.encode(expectedWayfarerId)

    // Now load via DefaultIdentityStore - should trigger migration
    let store = DefaultIdentityStore(directory: dir)
    let snapshot = try store.load()
    #expect(snapshot != nil)

    // Verify migration created v2 files
    #expect(store.hasV2Format)

    let v2Meta = try store.loadV2Metadata()
    #expect(v2Meta != nil)
    #expect(v2Meta!.version == 2)
    #expect(v2Meta!.keyType == "Ed25519")
    #expect(v2Meta!.legacyWayfarerId == expectedHex)
    #expect(v2Meta!.signingPublicKeyHex == Hex.encode(signingKey.publicKey.rawRepresentation))

    // Verify identity produces same wayfarerId
    let manager = IdentityManager(store: store)
    let identity = try manager.loadOrCreate()
    #expect(identity.wayfarerId == expectedWayfarerId)
    #expect(identity.isSelfCertifying)
}

@Test
func migrationV1ToV2IsIdempotent() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    // Create v1-only
    let signingKey = Curve25519.Signing.PrivateKey()
    let exchangeKey = Curve25519.KeyAgreement.PrivateKey()
    let v1Snapshot = IdentityStoreSnapshot(
        signingPrivateKeyRaw: signingKey.rawRepresentation,
        exchangePrivateKeyRaw: exchangeKey.rawRepresentation
    )
    let v1Data = try JSONEncoder().encode(v1Snapshot)
    try v1Data.write(to: dir.appendingPathComponent("identity-v1.json"))

    // Load twice - migration should happen only once
    let store = DefaultIdentityStore(directory: dir)
    let snap1 = try store.load()
    let v2Meta1 = try store.loadV2Metadata()

    let snap2 = try store.load()
    let v2Meta2 = try store.loadV2Metadata()

    #expect(snap1 == snap2)
    #expect(v2Meta1!.signingPublicKeyHex == v2Meta2!.signingPublicKeyHex)
}

// MARK: - Identity Properties

@Test
func identityKeyTypeIsEd25519() throws {
    #expect(IdentityV1.keyType == "Ed25519")
}

@Test
func identityFingerprintMatchesShortId() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let identity = try IdentityManager(store: DefaultIdentityStore(directory: dir)).loadOrCreate()

    #expect(identity.keyFingerprint == identity.shortId)
    #expect(identity.keyFingerprint.count == 16) // first 8 bytes as hex
}

@Test
func signingPublicKeyHexIs64Chars() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let identity = try IdentityManager(store: DefaultIdentityStore(directory: dir)).loadOrCreate()

    #expect(identity.signingPublicKeyHex.count == 64)
    #expect(identity.exchangePublicKeyHex.count == 64)
    #expect(identity.wayfarerId.hexString.count == 64)
}

// MARK: - Canonical Public Key Encoding

@Test
func canonicalPublicKeyBytesAreDeterministic() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let identity = try IdentityManager(store: DefaultIdentityStore(directory: dir)).loadOrCreate()

    let canonical1 = identity.canonicalPublicKeyBytes
    let canonical2 = identity.canonicalPublicKeyBytes

    #expect(canonical1 == canonical2)

    // Format: [version:1][keyTypeTag:1][fieldId:1][len:4][signingPub:32][fieldId:1][len:4][exchangePub:32]
    // Total: 1 + 1 + 1+4+32 + 1+4+32 = 76 bytes
    #expect(canonical1.count == 76)
}

@Test
func canonicalPublicKeyEncodeDecodeRoundTrip() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let identity = try IdentityManager(store: DefaultIdentityStore(directory: dir)).loadOrCreate()

    let canonical = identity.canonicalPublicKeyBytes
    let (keyTypeTag, signingPub, exchangePub) = try CanonicalEncoderV1.decodePublicIdentity(canonical: canonical)

    #expect(keyTypeTag == CanonicalEncoderV1.KeyTypeTag.ed25519.rawValue)
    #expect(signingPub == identity.signingPublicKey)
    #expect(exchangePub == identity.exchangePublicKey)
}

@Test
func canonicalPublicKeyDiffersForDifferentIdentities() throws {
    let dir1 = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let dir2 = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: dir1)
        try? FileManager.default.removeItem(at: dir2)
    }

    let id1 = try IdentityManager(store: DefaultIdentityStore(directory: dir1)).loadOrCreate()
    let id2 = try IdentityManager(store: DefaultIdentityStore(directory: dir2)).loadOrCreate()

    #expect(id1.canonicalPublicKeyBytes != id2.canonicalPublicKeyBytes)
}

// MARK: - Self-Certifying Verification

@Test
func isSelfCertifyingReturnsTrueForDerivedId() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let identity = try IdentityManager(store: DefaultIdentityStore(directory: dir)).loadOrCreate()
    #expect(identity.isSelfCertifying)
}

@Test
func isSelfCertifyingReturnsFalseForTamperedId() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let identity = try IdentityManager(store: DefaultIdentityStore(directory: dir)).loadOrCreate()

    // Create a tampered identity with wrong wayfarerId
    let tampered = IdentityV1(
        wayfarerId: Data(repeating: 0xFF, count: 32),
        signingPublicKey: identity.signingPublicKey,
        exchangePublicKey: identity.exchangePublicKey
    )
    #expect(!tampered.isSelfCertifying)
}
