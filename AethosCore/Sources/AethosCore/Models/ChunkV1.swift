import Foundation

public struct ChunkV1: Codable, Equatable, Sendable {
    public let version: ProtocolVersion
    public let index: Int
    public let bytes: Data
    public let id: Data

    public init(
        version: ProtocolVersion = .v1,
        index: Int,
        bytes: Data
    ) {
        self.version = version
        self.index = index
        self.bytes = bytes
        self.id = AethosIDs.chunkId(for: bytes)
    }
}
