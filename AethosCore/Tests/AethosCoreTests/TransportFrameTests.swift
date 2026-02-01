import Foundation
import Testing
@testable import AethosCore

@Test
func frameEncodeDecodeRoundTrip() throws {
    let frame = Frame(
        type: 9,
        id: Data(repeating: 0xAB, count: 32),
        partIndex: 0,
        partCount: 1,
        payload: Data("hello".utf8)
    )
    let encoded = frame.encode()
    let decoded = try Frame.decode(encoded)
    #expect(decoded == frame)
    #expect(decoded.sizeBytes == encoded.count)
}

@Test
func frameInvalidLengthFails() {
    let frame = Frame(
        type: 1,
        id: Data(repeating: 0xCD, count: 32),
        partIndex: 0,
        partCount: 1,
        payload: Data(repeating: 0xEE, count: 10)
    )
    var encoded = frame.encode()

    // Truncate payload.
    encoded.removeLast(1)

    var didThrow = false
    do {
        _ = try Frame.decode(encoded)
    } catch {
        didThrow = true
    }
    #expect(didThrow)
}
