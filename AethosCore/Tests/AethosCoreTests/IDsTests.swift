import Foundation
import Testing
@testable import AethosCore

@Test
func chunkIdHello() {
    let data = Data("hello".utf8)
    let digest = AethosIDs.chunkId(for: data)
    let hex = Hex.encode(digest)
    #expect(hex == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
}
