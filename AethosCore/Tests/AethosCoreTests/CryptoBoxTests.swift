import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Testing
@testable import AethosCore

@Test
func payloadRoundTrip() throws {
    let plaintext = Data((0..<1024).map { UInt8($0 % 251) })
    let encrypted = try CryptoBox.encryptPayload(plaintext)
    let decrypted = try CryptoBox.decryptPayload(encrypted)
    #expect(decrypted == plaintext)
    #expect(encrypted.alg == "chacha20poly1305")
}

@Test
func sealOpenRoundTrip() throws {
    let recipient = Curve25519.KeyAgreement.PrivateKey()
    let keyMaterial = Data((0..<32).map { _ in UInt8.random(in: 0...255) })

    let sealed = try CryptoBox.seal(keyMaterial, to: recipient.publicKey.rawRepresentation)
    let opened = try CryptoBox.open(sealed, with: recipient.rawRepresentation)

    #expect(opened == keyMaterial)
}

@Test
func openWithWrongKeyFails() throws {
    let recipientA = Curve25519.KeyAgreement.PrivateKey()
    let recipientB = Curve25519.KeyAgreement.PrivateKey()
    let keyMaterial = Data((0..<32).map { _ in UInt8.random(in: 0...255) })

    let sealed = try CryptoBox.seal(keyMaterial, to: recipientA.publicKey.rawRepresentation)

    var didThrow = false
    do {
        _ = try CryptoBox.open(sealed, with: recipientB.rawRepresentation)
    } catch {
        didThrow = true
    }
    #expect(didThrow)
}

@Test
func decryptRejectsUnknownAlgorithm() throws {
    let encrypted = EncryptedPayload(
        alg: "aes-gcm",
        nonce: Data(repeating: 0x01, count: 12),
        ciphertext: Data(repeating: 0x02, count: 32),
        key: Data(repeating: 0x03, count: 32)
    )

    var didThrowExpected = false
    do {
        _ = try CryptoBox.decryptPayload(encrypted)
    } catch CryptoBox.Error.unsupportedAlgorithm(let alg) {
        didThrowExpected = (alg == "aes-gcm")
    } catch {
        didThrowExpected = false
    }
    #expect(didThrowExpected)
}

@Test
func openRejectsWrongSealVersion() throws {
    let recipient = Curve25519.KeyAgreement.PrivateKey()
    let sealed = try CryptoBox.seal(Data(repeating: 0xAA, count: 32), to: recipient.publicKey.rawRepresentation)

    var wrongVersion = sealed
    wrongVersion[0] = 0xFF

    var didThrowExpected = false
    do {
        _ = try CryptoBox.open(wrongVersion, with: recipient.rawRepresentation)
    } catch CryptoBox.Error.invalidSealedFormat {
        didThrowExpected = true
    } catch {
        didThrowExpected = false
    }
    #expect(didThrowExpected)
}

@Test
func openRejectsTruncatedSealedBlob() throws {
    let recipient = Curve25519.KeyAgreement.PrivateKey()
    let sealed = try CryptoBox.seal(Data(repeating: 0xAA, count: 32), to: recipient.publicKey.rawRepresentation)

    let minimumValidCount = 1 + 32 + 12 + 16
    let truncated = sealed.prefix(max(0, minimumValidCount - 1))

    var didThrowExpected = false
    do {
        _ = try CryptoBox.open(Data(truncated), with: recipient.rawRepresentation)
    } catch CryptoBox.Error.invalidSealedFormat {
        didThrowExpected = true
    } catch {
        didThrowExpected = false
    }
    #expect(didThrowExpected)
}

@Test
func openRejectsTamperedCiphertextOrTag() throws {
    let recipient = Curve25519.KeyAgreement.PrivateKey()
    let sealed = try CryptoBox.seal(Data(repeating: 0x42, count: 32), to: recipient.publicKey.rawRepresentation)

    var tampered = sealed
    tampered[tampered.endIndex - 1] ^= 0x01

    var didThrow = false
    do {
        _ = try CryptoBox.open(tampered, with: recipient.rawRepresentation)
    } catch {
        didThrow = true
    }

    #expect(didThrow)
}
