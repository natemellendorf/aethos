import Foundation
import Testing
@testable import AethosCore

@Test
func chunkingCountAndSizes() {
    #expect(Chunking.chunk(Data()).count == 0)

    let one = Data([0x01])
    let oneChunks = Chunking.chunk(one)
    #expect(oneChunks.count == 1)
    #expect(oneChunks[0].bytes.count == 1)

    let big = Data(repeating: 0xAB, count: Chunking.chunkSize + 1)
    let bigChunks = Chunking.chunk(big)
    #expect(bigChunks.count == 2)
    #expect(bigChunks[0].bytes.count == Chunking.chunkSize)
    #expect(bigChunks[1].bytes.count == 1)
}

@Test
func manifestCorrectnessAndDeterminism() {
    let data = Data((0..<(Chunking.chunkSize * 2 + 123)).map { UInt8($0 % 251) })
    let manifest1 = Chunking.buildManifest(for: data)
    let manifest2 = Chunking.buildManifest(for: data)

    #expect(manifest1.totalBytes == data.count)
    #expect(manifest1.chunkSize == Chunking.chunkSize)
    #expect(manifest1.chunkIds.count == manifest1.chunkCount)
    #expect(manifest1.chunkIds == manifest2.chunkIds)

    let id1 = AethosIDs.manifestId(from: manifest1)
    let id2 = AethosIDs.manifestId(from: manifest2)
    #expect(id1 == id2)
}

@Test
func reassembleRoundTrip() throws {
    let data = Data((0..<(Chunking.chunkSize * 2 + 123)).map { UInt8($0 % 251) })
    let chunks = Chunking.chunk(data)
    let manifest = Chunking.buildManifest(for: data)

    var map: [Data: Data] = [:]
    map.reserveCapacity(chunks.count)
    for chunk in chunks {
        map[chunk.id] = chunk.bytes
    }

    let reassembled = try Chunking.reassemble(chunksById: map, manifest: manifest)
    #expect(reassembled == data)
}

@Test
func missingChunkFails() {
    let data = Data(repeating: 0xCD, count: Chunking.chunkSize + 1)
    let chunks = Chunking.chunk(data)
    let manifest = Chunking.buildManifest(for: data)

    var map: [Data: Data] = [:]
    for chunk in chunks {
        map[chunk.id] = chunk.bytes
    }

    let missingId = manifest.chunkIds[0]
    map[missingId] = nil

    var didThrowExpected = false
    do {
        _ = try Chunking.reassemble(chunksById: map, manifest: manifest)
    } catch let err as Chunking.ChunkingError {
        didThrowExpected = (err == .missingChunk(id: missingId))
    } catch {
        didThrowExpected = false
    }

    #expect(didThrowExpected)
}

@Test
func invalidChunkBytesFailReassembly() {
    let data = Data(repeating: 0xAB, count: Chunking.chunkSize + 1)
    let chunks = Chunking.chunk(data)
    let manifest = Chunking.buildManifest(for: data)

    var map: [Data: Data] = [:]
    for chunk in chunks {
        map[chunk.id] = chunk.bytes
    }

    let firstId = manifest.chunkIds[0]
    map[firstId] = Data(repeating: 0x00, count: chunks[0].bytes.count)

    var didThrowExpected = false
    do {
        _ = try Chunking.reassemble(chunksById: map, manifest: manifest)
    } catch let err as Chunking.ChunkingError {
        didThrowExpected = (err == .invalidChunk(id: firstId))
    } catch {
        didThrowExpected = false
    }

    #expect(didThrowExpected)
}

@Test
func dedupKeyIsStableAndLowercaseHex() {
    let chunkId = Data([0x00, 0x0A, 0xBC, 0xF0, 0x1D, 0x2E])

    let key1 = Chunking.dedupKey(chunkId: chunkId)
    let key2 = Chunking.dedupKey(chunkId: chunkId)

    #expect(key1 == key2)
    #expect(key1 == "000abcf01d2e")
    #expect(key1 == key1.lowercased())
}
