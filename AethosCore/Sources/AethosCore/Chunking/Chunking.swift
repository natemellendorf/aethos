import Foundation

public enum Chunking {
    public static let chunkSize: Int = 32_768

    public enum ChunkingError: Swift.Error, Equatable {
        case missingChunk(id: Data)
        case invalidChunk(id: Data)
    }

    // Empty payload behavior: returns 0 chunks.
    public static func chunk(_ data: Data) -> [ChunkV1] {
        guard !data.isEmpty else { return [] }

        var chunks: [ChunkV1] = []
        chunks.reserveCapacity((data.count + chunkSize - 1) / chunkSize)

        var index = 0
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let bytes = data.subdata(in: offset..<end)
            chunks.append(ChunkV1(index: index, bytes: bytes))
            index += 1
            offset = end
        }

        return chunks
    }

    public static func buildManifest(for data: Data) -> ManifestV1 {
        let chunks = chunk(data)
        let chunkIds = chunks.map { $0.id }
        return ManifestV1(totalSize: data.count, chunkIds: chunkIds)
    }

    public static func reassemble(chunksById: [Data: Data], manifest: ManifestV1) throws -> Data {
        var out = Data()
        out.reserveCapacity(manifest.totalSize)

        for id in manifest.chunkIds {
            guard let bytes = chunksById[id] else {
                throw ChunkingError.missingChunk(id: id)
            }
            guard AethosIDs.chunkId(for: bytes) == id else {
                throw ChunkingError.invalidChunk(id: id)
            }
            out.append(bytes)
        }

        return out
    }

    public static func dedupKey(chunkId: Data) -> String {
        Hex.encode(chunkId)
    }
}
