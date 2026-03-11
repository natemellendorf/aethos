import Foundation

/// Base64URL without padding (RFC 4648 §5), strict for gossip v1.
///
/// Decoding rules:
/// - MUST reject padding (`=`)
/// - MUST reject non-url alphabet (`+`, `/`) and whitespace
public enum GossipV1Base64URL {
    public static func encode(_ data: Data) -> String {
        // Foundation emits RFC 4648 base64 with padding.
        let b64 = data.base64EncodedString()
        return b64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ s: String) throws -> Data {
        if s.isEmpty {
            return Data()
        }

        // Fail fast: reject padding and non-url alphabet, plus whitespace.
        for c in s.utf8 {
            switch c {
            case 65...90, 97...122, 48...57, 45, 95: // A-Z a-z 0-9 - _
                continue
            case 61: // =
                throw GossipV1Error.invalidBase64URLPadding
            case 43, 47: // + /
                throw GossipV1Error.invalidBase64URLAlphabet
            default:
                throw GossipV1Error.invalidBase64URLAlphabet
            }
        }

        // Base64 length cannot be 1 mod 4.
        let mod = s.utf8.count % 4
        guard mod != 1 else { throw GossipV1Error.invalidBase64URLLength }

        let stdAlphabet = s
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let padCount = (4 - (stdAlphabet.utf8.count % 4)) % 4
        let padded = stdAlphabet + String(repeating: "=", count: padCount)

        guard let decoded = Data(base64Encoded: padded) else {
            throw GossipV1Error.invalidBase64URLDecoding
        }
        return decoded
    }
}
