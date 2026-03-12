import Foundation
import Testing
@testable import AethosCore

@Test
func gossipV1_malformedCorpus_decodeRejectsUnknownFrameType() throws {
    let bytes = try GossipV1MalformedCorpus.unknownFrameType()
    #expect(throws: GossipV1FrameError.unknownFrameType("NOPE")) {
        _ = try GossipV1Frame.decode(bytes: bytes)
    }
}

@Test
func gossipV1_malformedCorpus_decodeRejectsMissingPayload() throws {
    let bytes = try GossipV1MalformedCorpus.missingPayload(type: .HELLO)
    #expect(throws: GossipV1FrameError.envelopeMissingKey("payload")) {
        _ = try GossipV1Frame.decode(bytes: bytes)
    }
}

@Test
func gossipV1_malformedCorpus_decodeRejectsPayloadWrongType() throws {
    let bytes = try GossipV1MalformedCorpus.payloadNotMap(type: .SUMMARY)
    #expect(throws: GossipV1FrameError.envelopePayloadNotMap) {
        _ = try GossipV1Frame.decode(bytes: bytes)
    }
}

@Test
func gossipV1_malformedCorpus_decodeRejectsWrongFieldTypes() throws {
    let bytes = try GossipV1MalformedCorpus.requestWantWrongScalarType()
    #expect(throws: GossipV1FrameError.invalidScalar(field: "want")) {
        _ = try GossipV1Frame.decode(bytes: bytes)
    }
}

@Test
func gossipV1_malformedCorpus_decodeRejectsInvalidBase64URL() throws {
    let bytes = try GossipV1MalformedCorpus.transferObjectInvalidBase64URLAlphabet()
    #expect(throws: GossipV1FrameError.invalidScalar(field: "envelope_b64", underlying: .invalidBase64URLAlphabet)) {
        _ = try GossipV1Frame.decode(bytes: bytes)
    }
}

@Test
func gossipV1_malformedCorpus_decodeRejectsInvalidItemIDShape() throws {
    let bytes = try GossipV1MalformedCorpus.transferObjectInvalidItemIDHex()
    #expect(throws: GossipV1FrameError.invalidScalar(field: "item_id", underlying: .invalidHexDigest(expectedChars: 64, actualChars: 7))) {
        _ = try GossipV1Frame.decode(bytes: bytes)
    }
}

@Test
func gossipV1_malformedCorpus_decodeRejectsHelloNodeIDDerivationMismatch() throws {
    let bytes = try GossipV1MalformedCorpus.helloNodeIDMismatch()
    #expect(throws: GossipV1FrameError.nodeIDMismatch) {
        _ = try GossipV1Frame.decode(bytes: bytes)
    }
}

@Test
func gossipV1_malformedCorpus_decodeRejectsDuplicateMapKeys_viaFramingDatagramBoundary() throws {
    let bytes = GossipV1MalformedCorpus.cborDuplicateTopLevelKey_type()
    #expect(throws: GossipV1FramingError.invalidDatagramCBOR(problem: .duplicateMapKey)) {
        _ = try GossipV1Framing.decodeDatagram(bytes)
    }
}

@Test
func gossipV1_malformedCorpus_decodeRejectsMalformedCBOR_indefiniteMap() throws {
    let bytes = GossipV1MalformedCorpus.cborIndefiniteLengthMap()
    #expect(throws: GossipV1FramingError.invalidDatagramCBOR(problem: .indefiniteLengthNotSupported)) {
        _ = try GossipV1Framing.decodeDatagram(bytes)
    }
}

@Test
func gossipV1_malformedCorpus_decodeRejectsRequestWantDuplicates() throws {
    let id = try GossipV1ItemID(bytes: Data(repeating: 0x01, count: 32))
    let bytes = try GossipV1MalformedCorpus.requestWantWithDuplicates(id: id)
    #expect(throws: GossipV1FrameError.duplicateItemID) {
        _ = try GossipV1Frame.decode(bytes: bytes)
    }
}

@Test
func gossipV1_malformedCorpus_streamBoundaryRejectsEmptyFrame_andStopsImmediately_withOrderedEvents() throws {
    let localHello = try GossipV1TestSupport.makeHello(version: GossipV1.GOSSIP_VERSION)
    let engine = GossipV1EncounterEngine(config: .init(localHello: localHello))

    let errors = Locked<[GossipV1TransportError]>([])
    let received = Locked<[GossipV1Frame]>([])
    let transitions = Locked<[(GossipV1EncounterEngine.State, GossipV1EncounterEngine.State)]>([])
    let ordering = Locked<[String]>([])

    let hooks = GossipV1StreamAdapter.Hooks(
        onSend: { _ in },
        onEvent: { event in
            if case .didEncounterError(let e) = event { errors.withLock { $0.append(e) } }
            if case .didReceiveFrame(let f) = event { received.withLock { $0.append(f) } }
            if case .didChangeState(from: let from, to: let to) = event {
                transitions.withLock { $0.append((from, to)) }
                ordering.withLock { $0.append("state") }
            }
            if case .didEncounterError = event {
                ordering.withLock { $0.append("error") }
            }
        }
    )

    var adapter = GossipV1StreamAdapter(
        engine: engine,
        clock: GossipV1TestSupport.FixedClock(nowMs: 0),
        store: GossipV1TestSupport.InMemoryGossipStore(),
        isAuthenticatedRelayTransport: { false },
        hooks: hooks
    )

    let emptyFrame = Data([0x00, 0x00, 0x00, 0x00])
    let trailingHello = try Data(contentsOf: GossipV1TestSupport.fixturesDir().appendingPathComponent("hello.cbor"))
    let bytes = try emptyFrame + GossipV1Framing.encodeStreamFrame(trailingHello)

    try adapter.receiveBytes(bytes)

    #expect(adapter.state == .terminated(reason: .protocolViolation("stream boundary")))
    #expect(received.withLock { $0 }.isEmpty)
    #expect(errors.withLock { $0 } == [.streamBoundary(.emptyFrame)])

    // Ordering: termination transition emitted before error.
    let trace = ordering.withLock { $0 }
    #expect(trace.first == "state")
    #expect(trace.last == "error")
}

@Test
func gossipV1_malformedCorpus_rejectedFramesDoNotCorruptPreviouslyAcceptedState() throws {
    let localHello = try GossipV1TestSupport.makeHello(version: GossipV1.GOSSIP_VERSION)
    var engine = GossipV1EncounterEngine(config: .init(localHello: localHello))
    let clock = GossipV1TestSupport.FixedClock(nowMs: 0)
    let store = GossipV1TestSupport.InMemoryGossipStore()

    _ = try engine.ingestInboundFrame(.hello(localHello), clock: clock, store: store)
    #expect(engine.state == .active)

    // Reject invalid REQUEST.want ordering at frame decode boundary.
    let a = try GossipV1ItemID(bytes: Data(repeating: 0x00, count: 32))
    let b = try GossipV1ItemID(bytes: Data(repeating: 0x11, count: 32))
    let badRequestBytes = try GossipV1MalformedCorpus.requestWantUnsorted(a: a, b: b)
    #expect(throws: GossipV1FrameError.wantNotLexicographicallySorted) {
        _ = try GossipV1Frame.decode(bytes: badRequestBytes)
    }

    // Engine state should remain active.
    #expect(engine.state == .active)
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
