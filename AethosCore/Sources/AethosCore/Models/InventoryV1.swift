import Foundation

public struct InventoryV1: Codable, Equatable, Sendable {
    public static let maxManifestCount: Int = 500

    public let version: ProtocolVersion
    public let manifests: [String]
    public let generatedAtUnixMs: Int64

    public init(
        version: ProtocolVersion = .v1,
        manifests: [String],
        generatedAtUnixMs: Int64
    ) {
        self.version = version
        self.manifests = Array(manifests.prefix(Self.maxManifestCount))
        self.generatedAtUnixMs = generatedAtUnixMs
    }
}
