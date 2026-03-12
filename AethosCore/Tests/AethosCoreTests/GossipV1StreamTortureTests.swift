import Foundation
import XCTest
@testable import AethosCore

final class GossipV1StreamTortureTests: XCTestCase {
    func testStreamFramer_chunkingPatterns_decodeSingleFrame_forAllDeterministicChunkings() throws {
        let payload = try Data(contentsOf: GossipV1TestSupport.fixturesDir().appendingPathComponent("hello.cbor"))
        let streamFrame = try GossipV1Framing.encodeStreamFrame(payload)
        let patterns: [[Int]] = [
            [1],
            [2],
            [3],
            [4],
            [5],
            [7, 1],
            [1, 7],
            [1, 2, 3, 4, 5],
            [8, 1, 1, 1],
        ]

        for p in patterns {
            var framer = GossipV1StreamFramer()
            var out: [Data] = []
            for chunk in GossipV1TestSupport.split(streamFrame, repeating: p) {
                out.append(contentsOf: try framer.append(chunk))
            }
            XCTAssertEqual(out, [payload], "pattern \(p) failed")
            XCTAssertNoThrow(try framer.finish())
        }
    }

    func testStreamAdapter_chunkingTorture_twoFrames_allChunkPatterns_preserveOrder_andDecodeBoth() throws {
        let engine = GossipV1EncounterEngine(config: .init(localHello: try GossipV1TestSupport.makeHello(version: GossipV1.GOSSIP_VERSION)))
        let frame1 = try Data(contentsOf: GossipV1TestSupport.fixturesDir().appendingPathComponent("hello.cbor"))
        let frame2 = try Data(contentsOf: GossipV1TestSupport.fixturesDir().appendingPathComponent("summary.cbor"))
        let stream = try GossipV1Framing.encodeStreamFrame(frame1) + GossipV1Framing.encodeStreamFrame(frame2)

        let patterns: [[Int]] = [
            [1],
            [2],
            [4],
            [9, 1],
            [1, 9],
            [1, 2, 3, 4],
        ]

        for p in patterns {
            let received = Locked<[GossipV1Frame]>([])
            let hooks = GossipV1StreamAdapter.Hooks(
                onSend: { _ in },
                onEvent: { event in
                    if case .didReceiveFrame(let f) = event { received.withLock { $0.append(f) } }
                }
            )

            var adapter = GossipV1StreamAdapter(
                engine: engine,
                clock: GossipV1TestSupport.FixedClock(nowMs: 0),
                store: GossipV1TestSupport.InMemoryGossipStore(),
                isAuthenticatedRelayTransport: { false },
                hooks: hooks
            )

            for chunk in GossipV1TestSupport.split(stream, repeating: p) {
                try adapter.receiveBytes(chunk)
            }

            let frames = received.withLock { $0 }
            XCTAssertEqual(frames.count, 2, "pattern \(p) decoded \(frames.count)")
            XCTAssertEqual(frames[0], try GossipV1Frame.decode(bytes: frame1))
            XCTAssertEqual(frames[1], try GossipV1Frame.decode(bytes: frame2))
        }
    }

    func testStreamAdapter_fatalBoundaryStopsImmediately_andDoesNotProcessTrailingFrames_evenAcrossChunks() throws {
        let engine = GossipV1EncounterEngine(config: .init(localHello: try GossipV1TestSupport.makeHello(version: GossipV1.GOSSIP_VERSION)))

        let received = Locked<[GossipV1Frame]>([])
        let errors = Locked<[GossipV1TransportError]>([])
        let hooks = GossipV1StreamAdapter.Hooks(
            onSend: { _ in },
            onEvent: { event in
                if case .didReceiveFrame(let f) = event { received.withLock { $0.append(f) } }
                if case .didEncounterError(let e) = event { errors.withLock { $0.append(e) } }
            }
        )

        var adapter = GossipV1StreamAdapter(
            engine: engine,
            clock: GossipV1TestSupport.FixedClock(nowMs: 0),
            store: GossipV1TestSupport.InMemoryGossipStore(),
            isAuthenticatedRelayTransport: { false },
            hooks: hooks
        )

        let validHello = try Data(contentsOf: GossipV1TestSupport.fixturesDir().appendingPathComponent("hello.cbor"))
        let emptyFrame = Data([0x00, 0x00, 0x00, 0x00])
        let stream = try GossipV1Framing.encodeStreamFrame(validHello) + emptyFrame + GossipV1Framing.encodeStreamFrame(validHello)

        // Split so the adapter sees some bytes after the boundary violation.
        for chunk in GossipV1TestSupport.split(stream, repeating: [5, 1, 13, 2]) {
            try adapter.receiveBytes(chunk)
            if case .terminated = adapter.state { break }
        }

        XCTAssertEqual(adapter.state, .terminated(reason: .protocolViolation("stream boundary")))
        XCTAssertEqual(received.withLock { $0 }.count, 1)
        XCTAssertTrue(errors.withLock { $0 }.contains(.streamBoundary(.emptyFrame)))
    }
}

private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) {
        self.value = value
    }

    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
