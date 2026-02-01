import Foundation

public struct EncryptedPayload: Codable, Equatable, Sendable {
    public let alg: String
    public let nonce: Data
    public let ciphertext: Data

    // MVP0: raw payload key bytes are carried alongside the payload.
    // Future beads will replace this with sealed key material.
    public let key: Data

    public init(alg: String, nonce: Data, ciphertext: Data, key: Data) {
        self.alg = alg
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.key = key
    }
}
