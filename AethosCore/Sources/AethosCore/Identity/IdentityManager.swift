#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

public final class IdentityManager {
    private let store: any IdentityStore
    private var cached: IdentityStoreSnapshot?

    public init(store: any IdentityStore = DefaultIdentityStore()) {
        self.store = store
    }

    public func loadOrCreate() throws -> IdentityV1 {
        if let cached {
            return try identity(from: cached)
        }
        if let snapshot = try store.load() {
            cached = snapshot
            return try identity(from: snapshot)
        }

        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *) {
            let signing = Curve25519.Signing.PrivateKey()
            let exchange = Curve25519.KeyAgreement.PrivateKey()

            let snapshot = IdentityStoreSnapshot(
                signingPrivateKeyRaw: signing.rawRepresentation,
                exchangePrivateKeyRaw: exchange.rawRepresentation
            )
            try store.save(snapshot)
            cached = snapshot
            return try identity(from: snapshot)
        }

        fatalError("IdentityManager requires CryptoKit (macOS 10.15+/iOS 13+)")
    }

    public func sign(_ data: Data) throws -> Data {
        let snapshot = try requireSnapshot()
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *) {
            let signing = try Curve25519.Signing.PrivateKey(rawRepresentation: snapshot.signingPrivateKeyRaw)
            return try signing.signature(for: data)
        }

        fatalError("IdentityManager.sign requires CryptoKit (macOS 10.15+/iOS 13+)")
    }

    public static func verify(signature: Data, data: Data, signingPublicKey: Data) throws -> Bool {
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *) {
            let pub = try Curve25519.Signing.PublicKey(rawRepresentation: signingPublicKey)
            return pub.isValidSignature(signature, for: data)
        }

        fatalError("IdentityManager.verify requires CryptoKit (macOS 10.15+/iOS 13+)")
    }

    public func exportExchangePrivateKeyRaw() throws -> Data {
        let snapshot = try requireSnapshot()
        return snapshot.exchangePrivateKeyRaw
    }

    private func requireSnapshot() throws -> IdentityStoreSnapshot {
        if let cached { return cached }
        _ = try loadOrCreate()
        guard let cached else {
            throw CocoaError(.fileReadUnknown)
        }
        return cached
    }

    private func identity(from snapshot: IdentityStoreSnapshot) throws -> IdentityV1 {
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *) {
            let signing = try Curve25519.Signing.PrivateKey(rawRepresentation: snapshot.signingPrivateKeyRaw)
            let exchange = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: snapshot.exchangePrivateKeyRaw)

            let signingPub = signing.publicKey.rawRepresentation
            let exchangePub = exchange.publicKey.rawRepresentation
            let wayfarerId = AethosIDs.sha256(signingPub)

            return IdentityV1(
                wayfarerId: wayfarerId,
                signingPublicKey: signingPub,
                exchangePublicKey: exchangePub
            )
        }

        fatalError("IdentityManager.identity requires CryptoKit (macOS 10.15+/iOS 13+)")
    }
}
