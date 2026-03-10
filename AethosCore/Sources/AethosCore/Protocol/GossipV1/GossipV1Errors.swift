import Foundation

public enum GossipV1Error: Swift.Error, Equatable, Sendable {
    case invalidHexDigest(expectedChars: Int, actualChars: Int)
    case invalidHexCharacter
    case invalidDigestByteCount(expected: Int, actual: Int)
    case invalidBase64URLPadding
    case invalidBase64URLAlphabet
    case invalidBase64URLLength
    case invalidBase64URLDecoding

    @available(*, deprecated, message: "Gossip v1 frame parsing/validation now surfaces bloom size issues as GossipV1FrameError.invalidBloomByteCount(expected:actual:).")
    case invalidBloomByteCount(expected: Int, actual: Int)
}
