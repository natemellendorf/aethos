import CryptoKit
import Foundation

public enum CryptoBox {
    public enum Error: Swift.Error {
        case unsupportedAlgorithm(String)
        case invalidSealedFormat
    }

    private static let payloadAlg = "chacha20poly1305"
    private static let sealVersion: UInt8 = 1
    private static let sealSalt = Data("AethosCryptoBoxSealV1".utf8)

    public static func encryptPayload(_ plaintext: Data) throws -> EncryptedPayload {
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *) {
            let key = SymmetricKey(size: .bits256)
            let keyBytes = key.withUnsafeBytes { Data($0) }

            let nonce = ChaChaPoly.Nonce()
            let sealed = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce)

            // Prefer parsing the combined representation to avoid any nonce encoding ambiguity.
            let combined = sealed.combined
            let nonceBytes = combined.prefix(12)
            let ciphertextPlusTag = combined.dropFirst(12)

            return EncryptedPayload(
                alg: payloadAlg,
                nonce: Data(nonceBytes),
                ciphertext: Data(ciphertextPlusTag),
                key: keyBytes
            )
        }

        fatalError("CryptoBox.encryptPayload requires CryptoKit (macOS 10.15+/iOS 13+)")
    }

    public static func decryptPayload(_ encrypted: EncryptedPayload) throws -> Data {
        guard encrypted.alg == payloadAlg else {
            throw Error.unsupportedAlgorithm(encrypted.alg)
        }

        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *) {
            let key = SymmetricKey(data: encrypted.key)
            let combined = encrypted.nonce + encrypted.ciphertext
            let box = try ChaChaPoly.SealedBox(combined: combined)
            return try ChaChaPoly.open(box, using: key)
        }

        fatalError("CryptoBox.decryptPayload requires CryptoKit (macOS 10.15+/iOS 13+)")
    }

    // Sealed payload-key format (MVP0):
    // [1 byte version][32 bytes ephemeralPublicKey][12 bytes nonce][ciphertext || tag]
    public static func seal(_ keyMaterial: Data, to recipientPublicKey: Data) throws -> Data {
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *) {
            let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientPublicKey)
            let ephemeral = Curve25519.KeyAgreement.PrivateKey()
            let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)

            let symmetricKey = shared.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: sealSalt,
                sharedInfo: Data(),
                outputByteCount: 32
            )

            let nonce = ChaChaPoly.Nonce()
            let sealed = try ChaChaPoly.seal(keyMaterial, using: symmetricKey, nonce: nonce)

            var out = Data()
            out.reserveCapacity(1 + 32 + 12 + sealed.ciphertext.count + sealed.tag.count)

            out.append(sealVersion)
            out.append(ephemeral.publicKey.rawRepresentation)
            out.append(nonce.withUnsafeBytes { Data($0) })
            out.append(sealed.ciphertext)
            out.append(sealed.tag)

            return out
        }

        fatalError("CryptoBox.seal requires CryptoKit (macOS 10.15+/iOS 13+)")
    }

    public static func open(_ sealed: Data, with recipientPrivateKey: Data) throws -> Data {
        let headerSize = 1 + 32 + 12
        guard sealed.count >= headerSize + 16 else { throw Error.invalidSealedFormat }
        guard sealed.first == sealVersion else { throw Error.invalidSealedFormat }

        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *) {
            let ephStart = sealed.startIndex + 1
            let ephEnd = ephStart + 32
            let nonceStart = ephEnd
            let nonceEnd = nonceStart + 12
            let bodyStart = nonceEnd

            let ephBytes = sealed[ephStart..<ephEnd]
            let nonceBytes = sealed[nonceStart..<nonceEnd]
            let body = sealed[bodyStart...]
            guard body.count >= 16 else { throw Error.invalidSealedFormat }

            let tagStart = body.endIndex - 16
            let ciphertext = body[..<tagStart]
            let tag = body[tagStart...]

            let recipient = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: recipientPrivateKey)
            let ephemeralPublic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Data(ephBytes))
            let shared = try recipient.sharedSecretFromKeyAgreement(with: ephemeralPublic)

            let symmetricKey = shared.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: sealSalt,
                sharedInfo: Data(),
                outputByteCount: 32
            )

            let nonce = try ChaChaPoly.Nonce(data: Data(nonceBytes))
            let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            return try ChaChaPoly.open(box, using: symmetricKey)
        }

        fatalError("CryptoBox.open requires CryptoKit (macOS 10.15+/iOS 13+)")
    }
}
