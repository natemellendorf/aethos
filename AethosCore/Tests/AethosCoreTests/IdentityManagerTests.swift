import CryptoKit
import Foundation
import Testing
@testable import AethosCore

@Test
func loadOrCreateIsStable() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = DefaultIdentityStore(directory: dir)
    let managerA = IdentityManager(store: store)
    let id1 = try managerA.loadOrCreate()

    let managerB = IdentityManager(store: store)
    let id2 = try managerB.loadOrCreate()

    #expect(id1.wayfarerId == id2.wayfarerId)
    #expect(id1.signingPublicKey == id2.signingPublicKey)
    #expect(id1.exchangePublicKey == id2.exchangePublicKey)
    #expect(id1.wayfarerId.count == 32)
    #expect(id1.shortId.count == 16)
    #expect(id1.exchangePublicKey.count == 32)
}

@Test
func signVerify() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let manager = IdentityManager(store: DefaultIdentityStore(directory: dir))
    let identity = try manager.loadOrCreate()

    let data = Data("receipt-bytes".utf8)
    let sig = try manager.sign(data)

    let ok = try IdentityManager.verify(signature: sig, data: data, signingPublicKey: identity.signingPublicKey)
    #expect(ok)

    let modified = Data("receipt-bytes!".utf8)
    let bad = try IdentityManager.verify(signature: sig, data: modified, signingPublicKey: identity.signingPublicKey)
    #expect(!bad)
}

@Test
func exchangeKeysWorkWithCryptoBox() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let manager = IdentityManager(store: DefaultIdentityStore(directory: dir))
    let identity = try manager.loadOrCreate()
    let exchangePriv = try manager.exportExchangePrivateKeyRaw()

    let keyMaterial = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    let sealed = try CryptoBox.seal(keyMaterial, to: identity.exchangePublicKey)
    let opened = try CryptoBox.open(sealed, with: exchangePriv)
    #expect(opened == keyMaterial)
}
