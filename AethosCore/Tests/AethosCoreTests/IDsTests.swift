import Foundation
import XCTest

@testable import AethosCore

final class IDsTests: XCTestCase {
    func testSha256Hello() {
        let digest = AethosIDs.sha256(Data("hello".utf8))
        XCTAssertEqual(digest.hexString, "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }
}
