import Foundation
import Testing
@testable import AethosCore

@Test
func metadataEncodesToSingleFrameAndDecodes() throws {
    let manifest = ManifestV1(totalSize: 100, chunkIds: [Data(repeating: 0x11, count: 32)])
    let bytes = CanonicalEncoderV1.encode(manifest)
    let item = CargoItem.manifest(bytes)

    let frames = try CargoCodec.encode(item, maxFramePayloadBytes: 1024)
    #expect(frames.count == 1)

    let frame = frames[0]
    #expect(frame.type == CargoCodec.FrameType.manifest.rawValue)
    #expect(frame.partIndex == 0)
    #expect(frame.partCount == 1)
    #expect(frame.id == AethosIDs.manifestId(canonicalBytes: bytes))
    #expect(frame.payload == bytes)

    let frag = try CargoCodec.decode(frame)
    #expect(frag == .metadata(type: frame.type, id: frame.id, bytes: bytes))
}

@Test
func chunkEncodesToMultipleFramesAndReassembles() throws {
    let chunkId = Data(repeating: 0xAA, count: 32)
    let bytes = Data((0..<3000).map { UInt8($0 % 251) })
    let frames = try CargoCodec.encode(.chunk(id: chunkId, bytes: bytes), maxFramePayloadBytes: 1024)
    #expect(frames.count == 3)

    var parts: [UInt16: Data] = [:]
    var partCount: UInt16?
    for f in frames {
        #expect(f.type == CargoCodec.FrameType.chunk.rawValue)
        #expect(f.id == chunkId)
        let frag = try CargoCodec.decode(f)
        guard case let .chunkPart(id, idx, cnt, part) = frag else {
            Issue.record("Expected chunkPart")
            return
        }
        #expect(id == chunkId)
        parts[idx] = part
        partCount = cnt
    }

    guard let cnt = partCount else {
        Issue.record("Missing partCount")
        return
    }

    var rebuilt = Data()
    for i in 0..<cnt {
        guard let part = parts[i] else {
            Issue.record("Missing part \(i)")
            return
        }
        rebuilt.append(part)
    }
    #expect(rebuilt == bytes)
}

@Test
func invalidChunkPartIndexThrows() throws {
    let frame = Frame(
        type: CargoCodec.FrameType.chunk.rawValue,
        id: Data(repeating: 0x01, count: 32),
        partIndex: 2,
        partCount: 2,
        payload: Data([0x00])
    )

    var didThrow = false
    do {
        _ = try CargoCodec.decode(frame)
    } catch {
        didThrow = true
    }
    #expect(didThrow)
}
