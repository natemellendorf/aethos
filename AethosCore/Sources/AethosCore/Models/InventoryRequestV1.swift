import Foundation

public struct InventoryRequestV1: Codable, Equatable, Sendable {
    public let version: ProtocolVersion
    public let want: [String]

    public init(
        version: ProtocolVersion = .v1,
        want: [String]
    ) {
        self.version = version
        self.want = want
    }
}
