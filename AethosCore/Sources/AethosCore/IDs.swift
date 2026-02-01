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

    public static func manifestId(from manifest: ManifestV1) -> Data {
        manifestId(canonicalBytes: CanonicalEncoderV1.encode(manifest))
    }

    public static func envelopeId(canonicalBytes: Data) -> Data {
        sha256(canonicalBytes)
    }

    public static func envelopeId(from envelope: EnvelopeV1) -> Data {
        envelopeId(canonicalBytes: CanonicalEncoderV1.encode(envelope))
    }

    public static func receiptId(canonicalBytes: Data) -> Data {
        sha256(canonicalBytes)
    }

    public static func receiptId(from receipt: ReceiptV1) -> Data {
        receiptId(canonicalBytes: CanonicalEncoderV1.encode(receipt))
    }
}
