import Foundation

public enum GossipV1Error: Swift.Error, Equatable {
    case invalidHexDigest(expectedChars: Int, actualChars: Int)
    case invalidHexCharacter
    case invalidDigestByteCount(expected: Int, actual: Int)
    case invalidBase64URLPadding
    case invalidBase64URLAlphabet
    case invalidBase64URLLength
    case invalidBase64URLDecoding
}
