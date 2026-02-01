import Foundation

public struct IdentityV1: Codable, Equatable, Sendable {
    public let wayfarerId: Data
    public var shortId: String {
        Hex.encode(wayfarerId.prefix(8))
    }

    public let signingPublicKey: Data
    public let exchangePublicKey: Data

    public init(wayfarerId: Data, signingPublicKey: Data, exchangePublicKey: Data) {
        self.wayfarerId = wayfarerId
        self.signingPublicKey = signingPublicKey
        self.exchangePublicKey = exchangePublicKey
    }
}
