import CryptoKit
import Foundation

public enum AethosIDs {
    public static func sha256(_ data: Data) -> Data {
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *) {
            let digest = SHA256.hash(data: data)
            return digest.withUnsafeBytes { Data($0) }
        }

        fatalError("AethosIDs.sha256 requires CryptoKit (macOS 10.15+/iOS 13+)")
    }

    public static func chunkId(for bytes: Data) -> Data {
        sha256(bytes)
    }

    public static func manifestId(canonicalBytes: Data) -> Data {
        sha256(canonicalBytes)
    }

    public static func envelopeId(canonicalBytes: Data) -> Data {
        sha256(canonicalBytes)
    }

    public static func receiptId(canonicalBytes: Data) -> Data {
        sha256(canonicalBytes)
    }
}
