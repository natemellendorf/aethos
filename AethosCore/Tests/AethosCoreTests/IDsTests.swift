import Foundation
import Testing
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import AethosCore

@Test
func chunkIdHello() {
    let data = Data("hello".utf8)
    let digest = AethosIDs.chunkId(for: data)
    let hex = Hex.encode(digest)
    #expect(hex == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
}

@Test
func sha256MatchesProviderDigestFixture() {
    let fixture = Data("aethos-provider-parity".utf8)
    let aethosDigest = AethosIDs.sha256(fixture)
    let providerDigest = SHA256.hash(data: fixture).withUnsafeBytes { Data($0) }

    #expect(aethosDigest == providerDigest)
    #expect(Hex.encode(aethosDigest) == "f7c1cb80aefc669379c01c64e2739ef742412c1458c0d219bd8de34926482f60")
}
