import Foundation
import CryptoKit
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
