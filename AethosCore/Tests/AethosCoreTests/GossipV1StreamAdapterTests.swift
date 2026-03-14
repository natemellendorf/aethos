import Foundation
import XCTest
@testable import AethosCore

private typealias Locked<T> = GossipV1TestSupport.Locked<T>

final class GossipV1StreamAdapterTests: XCTestCase {
    func testSendingHelloEmitsStreamBytes_lengthPrefixPlusPayload() throws {
        let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
        let engine = GossipV1EncounterEngine(config: .init(localHello: localHello))

        let sent = Locked<[Data]>([])
        let hooks = GossipV1StreamAdapter.Hooks(
            onSend: { bytes in
                sent.withLock { $0.append(bytes) }
            },
            onEvent: { _ in }
        )

        let adapter = GossipV1StreamAdapter(
            engine: engine,
            clock: FixedClock(nowMs: 0),
            store: InMemoryGossipStore(),
            isAuthenticatedRelayTransport: { false },
            hooks: hooks
        )
        adapter.sendHello()

        let sentSnapshot = sent.withLock { $0 }
        XCTAssertEqual(sentSnapshot.count, 1)
        let expectedPayload = engine.buildHello().encode()
        let expected = try GossipV1Framing.encodeStreamFrame(expectedPayload)
        XCTAssertEqual(sentSnapshot.first, expected)
    }

    func testHelloVersionMismatchProducesEventError() throws {
        let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
        let engine = GossipV1EncounterEngine(config: .init(localHello: localHello))

        let events = Locked<[GossipV1StreamAdapter.Event]>([])
        let hooks = GossipV1StreamAdapter.Hooks(
            onSend: { _ in },
            onEvent: { event in
                events.withLock { $0.append(event) }
            }
        )

        var adapter = GossipV1StreamAdapter(
            engine: engine,
            clock: FixedClock(nowMs: 0),
            store: InMemoryGossipStore(),
            isAuthenticatedRelayTransport: { false },
            hooks: hooks
        )

        let mismatchFrameBytes = try GossipV1TestSupport.fixtureData("hello_version_mismatch.cbor")
        let streamBytes = try GossipV1Framing.encodeStreamFrame(mismatchFrameBytes)
        try adapter.receiveBytes(streamBytes)

        // Find the error event.
        let errorEvents = events.withLock { $0 }.compactMap { event -> GossipV1TransportError? in
            guard case .didEncounterError(let err) = event else { return nil }
            return err
        }
        XCTAssertEqual(errorEvents.count, 1)
        XCTAssertEqual(
            errorEvents.first,
            .encounterValidation(.invalidHelloVersion(expected: GossipV1.GOSSIP_VERSION, actual: GossipV1.GOSSIP_VERSION + 1))
        )
    }

    func testHelloVersionMismatch_emitsStateChangeBeforeEncounterError() throws {
        let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
        let engine = GossipV1EncounterEngine(config: .init(localHello: localHello))

        let events = Locked<[GossipV1StreamAdapter.Event]>([])
        let hooks = GossipV1StreamAdapter.Hooks(
            onSend: { _ in },
            onEvent: { event in
                events.withLock { $0.append(event) }
            }
        )

        var adapter = GossipV1StreamAdapter(
            engine: engine,
            clock: FixedClock(nowMs: 0),
            store: InMemoryGossipStore(),
            isAuthenticatedRelayTransport: { false },
            hooks: hooks
        )

        let mismatchFrameBytes = try GossipV1TestSupport.fixtureData("hello_version_mismatch.cbor")
        let streamBytes = try GossipV1Framing.encodeStreamFrame(mismatchFrameBytes)
        try adapter.receiveBytes(streamBytes)

        let snapshot = events.withLock { $0 }
        let stateIdx = snapshot.firstIndex { event in
            if case .didChangeState = event { return true }
            return false
        }
        let errorIdx = snapshot.firstIndex { event in
            if case .didEncounterError = event { return true }
            return false
        }
        XCTAssertNotNil(stateIdx)
        XCTAssertNotNil(errorIdx)
        XCTAssertLessThan(stateIdx!, errorIdx!)
    }

    func testReceiveBytes_twoFramesInOneBuffer_firstInvalidSecondValid_secondStillProcessedWhenFirstNonFatal() throws {
        let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
        let engine = GossipV1EncounterEngine(config: .init(localHello: localHello))

        let receivedFrames = Locked<[GossipV1Frame]>([])
        let errorEvents = Locked<[GossipV1TransportError]>([])
        let hooks = GossipV1StreamAdapter.Hooks(
            onSend: { _ in },
            onEvent: { event in
                switch event {
                case .didReceiveFrame(let frame):
                    receivedFrames.withLock { $0.append(frame) }
                case .didEncounterError(let err):
                    errorEvents.withLock { $0.append(err) }
                default:
                    break
                }
            }
        )

        var adapter = GossipV1StreamAdapter(
            engine: engine,
            clock: FixedClock(nowMs: 0),
            store: InMemoryGossipStore(),
            isAuthenticatedRelayTransport: { false },
            hooks: hooks
        )

        // This fixture exceeds MAX_TRANSFER_BYTES at the TRANSFER decode boundary and should fail
        // as a non-fatal invalid-frame (not a boundary error).
        let invalidFirst = try GossipV1TestSupport.fixtureData("transfer_oversize_bytes.cbor")
        let validSecond = try GossipV1TestSupport.fixtureData("hello.cbor")
        let streamBytes = try GossipV1Framing.encodeStreamFrame(invalidFirst) + GossipV1Framing.encodeStreamFrame(validSecond)

        try adapter.receiveBytes(streamBytes)

        let frames = receivedFrames.withLock { $0 }
        XCTAssertEqual(frames.count, 1)
        guard case .hello(let decodedHello)? = frames.first else {
            return XCTFail("Expected HELLO frame")
        }
        XCTAssertEqual(decodedHello.version, localHello.version)

        let errors = errorEvents.withLock { $0 }
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.first, .invalidFrame(.transferTotalEnvelopeBytesTooLarge(max: GossipV1.MAX_TRANSFER_BYTES, actual: 524_294)))
    }

    func testReceiveBytes_stopImmediatelyAfterTermination_remainingFramesInSameBufferNotProcessed() throws {
        let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
        let engine = GossipV1EncounterEngine(config: .init(localHello: localHello))

        let receivedFrames = Locked<[GossipV1Frame]>([])
        let hooks = GossipV1StreamAdapter.Hooks(
            onSend: { _ in },
            onEvent: { event in
                if case .didReceiveFrame(let frame) = event {
                    receivedFrames.withLock { $0.append(frame) }
                }
            }
        )

        var adapter = GossipV1StreamAdapter(
            engine: engine,
            clock: FixedClock(nowMs: 0),
            store: InMemoryGossipStore(),
            isAuthenticatedRelayTransport: { false },
            hooks: hooks
        )

        let terminatingHello = try GossipV1TestSupport.fixtureData("hello_version_mismatch.cbor")
        let secondHello = try GossipV1TestSupport.fixtureData("hello.cbor")
        let streamBytes = try GossipV1Framing.encodeStreamFrame(terminatingHello) + GossipV1Framing.encodeStreamFrame(secondHello)

        try adapter.receiveBytes(streamBytes)

        // Only the first frame should be decoded/emitted; termination stops further processing.
        XCTAssertEqual(receivedFrames.withLock { $0 }.count, 1)
    }

    func testRelayIngestUnauthenticated_emitsDidReceiveFrame_butDoesNotCallOnApplicationFrame() throws {
        let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
        let engine = GossipV1EncounterEngine(config: .init(localHello: localHello))

        let didReceive = Locked<[GossipV1Frame]>([])
        let onApplicationFrames = Locked<[GossipV1Frame]>([])
        let hooks = GossipV1StreamAdapter.Hooks(
            onSend: { _ in },
            onEvent: { event in
                if case .didReceiveFrame(let frame) = event {
                    didReceive.withLock { $0.append(frame) }
                }
            },
            onApplicationFrame: { frame in
                onApplicationFrames.withLock { $0.append(frame) }
            }
        )

        var adapter = GossipV1StreamAdapter(
            engine: engine,
            clock: FixedClock(nowMs: 0),
            store: InMemoryGossipStore(),
            isAuthenticatedRelayTransport: { false },
            hooks: hooks
        )

        let relayIngestBytes = try GossipV1TestSupport.fixtureData("relay_ingest_unauthenticated.cbor")
        let streamBytes = try GossipV1Framing.encodeStreamFrame(relayIngestBytes)
        try adapter.receiveBytes(streamBytes)

        XCTAssertEqual(didReceive.withLock { $0 }.count, 1)
        XCTAssertEqual(onApplicationFrames.withLock { $0 }.count, 0)
    }

    func testReceiveBytes_relayIngestObserverThrowingCancellationError_isRethrown() throws {
        let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
        let engine = GossipV1EncounterEngine(config: .init(localHello: localHello))

        let observer = CancellationThrowingRelayObserver()
        let hooks = GossipV1StreamAdapter.Hooks(onSend: { _ in }, onEvent: { _ in })
        var adapter = GossipV1StreamAdapter(
            engine: engine,
            clock: FixedClock(nowMs: 0),
            store: InMemoryGossipStore(),
            relayObserver: observer,
            isAuthenticatedRelayTransport: { true },
            hooks: hooks
        )

        let relayIngestBytes = try GossipV1TestSupport.fixtureData("relay_ingest.cbor")
        let streamBytes = try GossipV1Framing.encodeStreamFrame(relayIngestBytes)

        XCTAssertThrowsError(try adapter.receiveBytes(streamBytes)) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testReceiveBytes_relayIngestObserverThrowingValidationError_isMappedToRelayIngestValidationTransportError_andDoesNotTerminateEncounter() throws {
        let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
        let engine = GossipV1EncounterEngine(config: .init(localHello: localHello))

        let thrown: GossipV1EncounterEngine.ValidationError = .encounterTerminated
        // NOTE: Relay-ingest validation errors are not produced by the engine today.
        // This observer is an intentional seam to force a ValidationError and verify the
        // adapter maps it into the relay-ingest transport error domain.
        let observer = RelayIngestValidationErrorSeamObserver(error: thrown)

        let errors = Locked<[GossipV1TransportError]>([])
        let hooks = GossipV1StreamAdapter.Hooks(
            onSend: { _ in },
            onEvent: { event in
                guard case .didEncounterError(let err) = event else { return }
                errors.withLock { $0.append(err) }
            }
        )

        var adapter = GossipV1StreamAdapter(
            engine: engine,
            clock: FixedClock(nowMs: 0),
            store: InMemoryGossipStore(),
            relayObserver: observer,
            isAuthenticatedRelayTransport: { true },
            hooks: hooks
        )

        let itemID = GossipV1ItemID.derive(fromEnvelopeBytes: Data([0x01]))
        let relayIngest = try GossipV1RelayIngestFrame(itemIDs: [itemID])
        let streamBytes = try GossipV1Framing.encodeStreamFrame(GossipV1Frame.relayIngest(relayIngest).encode())
        try adapter.receiveBytes(streamBytes)

        XCTAssertEqual(errors.withLock { $0 }, [.relayIngestValidation(thrown)])

        // Observer errors must not change encounter state.
        XCTAssertEqual(adapter.state, .awaitingHello)
    }

    func testReceiveBytes_relayIngestObserverNonCancellationError_emitsErrorEvent_andContinuesProcessingFutureFrames() throws {
        let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
        let engine = GossipV1EncounterEngine(config: .init(localHello: localHello))

        let thrown = FixtureError()
        let observer = ThrowingRelayObserver(error: thrown)

        let events = Locked<[GossipV1StreamAdapter.Event]>([])
        let hooks = GossipV1StreamAdapter.Hooks(
            onSend: { _ in },
            onEvent: { event in
                events.withLock { $0.append(event) }
            }
        )

        var adapter = GossipV1StreamAdapter(
            engine: engine,
            clock: FixedClock(nowMs: 0),
            store: InMemoryGossipStore(),
            relayObserver: observer,
            isAuthenticatedRelayTransport: { true },
            hooks: hooks
        )

        let itemID = GossipV1ItemID.derive(fromEnvelopeBytes: Data([0x01]))
        let ingest = try GossipV1RelayIngestFrame(itemIDs: [itemID])
        let relayBytes = try GossipV1Framing.encodeStreamFrame(GossipV1Frame.relayIngest(ingest).encode())
        let helloBytes = try GossipV1TestSupport.fixtureData("hello.cbor")
        let helloStreamBytes = try GossipV1Framing.encodeStreamFrame(helloBytes)

        // Relay ingest observer error must not stop processing subsequent frames.
        try adapter.receiveBytes(relayBytes + helloStreamBytes)

        let snapshot = events.withLock { $0 }
        XCTAssertTrue(snapshot.contains { event in
            if case .didEncounterError(.unexpected) = event { return true }
            return false
        })
        XCTAssertTrue(snapshot.contains { event in
            if case .didReceiveFrame(.hello) = event { return true }
            return false
        })
        XCTAssertTrue(snapshot.contains { event in
            if case .didChangeState(from: .awaitingHello, to: .active) = event { return true }
            return false
        })
    }

    func testReceiveBytes_twoFramesInOneBuffer_firstInvalidDatagramCBOR_secondValid_secondStillProcessedWhenFirstNonFatal() throws {
        let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
        let engine = GossipV1EncounterEngine(config: .init(localHello: localHello))

        let receivedFrames = Locked<[GossipV1Frame]>([])
        let errorEvents = Locked<[GossipV1TransportError]>([])
        let hooks = GossipV1StreamAdapter.Hooks(
            onSend: { _ in },
            onEvent: { event in
                switch event {
                case .didReceiveFrame(let frame):
                    receivedFrames.withLock { $0.append(frame) }
                case .didEncounterError(let err):
                    errorEvents.withLock { $0.append(err) }
                default:
                    break
                }
            }
        )

        var adapter = GossipV1StreamAdapter(
            engine: engine,
            clock: FixedClock(nowMs: 0),
            store: InMemoryGossipStore(),
            isAuthenticatedRelayTransport: { false },
            hooks: hooks
        )

        // Invalid CBOR: a single byte 0xBF indicates an indefinite-length map, which
        // is forbidden by canonical CBOR and should be rejected at the framing layer.
        let invalidFirst = Data([0xBF])
        let validSecond = try GossipV1TestSupport.fixtureData("hello.cbor")
        let expectedSecondFrame = try GossipV1Frame.decode(bytes: validSecond)
        let streamBytes = try GossipV1Framing.encodeStreamFrame(invalidFirst) + GossipV1Framing.encodeStreamFrame(validSecond)

        try adapter.receiveBytes(streamBytes)

        let frames = receivedFrames.withLock { $0 }
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first, expectedSecondFrame)

        let errors = errorEvents.withLock { $0 }
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(
            errors.first,
            .streamBoundary(.invalidDatagramCBOR(problem: .indefiniteLengthNotSupported))
        )
    }

    func testReceiveBytes_twoFramesInOneBuffer_firstValidSecondBoundaryError_fatalStopsProcessing_butDoesNotDropFirstFrame() throws {
        let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
        let engine = GossipV1EncounterEngine(config: .init(localHello: localHello))

        let receivedFrames = Locked<[GossipV1Frame]>([])
        let errors = Locked<[GossipV1TransportError]>([])
        let stateTransitions = Locked<[(GossipV1EncounterEngine.State, GossipV1EncounterEngine.State)]>([])
        let hooks = GossipV1StreamAdapter.Hooks(
            onSend: { _ in },
            onEvent: { event in
                switch event {
                case .didReceiveFrame(let frame):
                    receivedFrames.withLock { $0.append(frame) }
                case .didEncounterError(let err):
                    errors.withLock { $0.append(err) }
                case .didChangeState(from: let from, to: let to):
                    stateTransitions.withLock { $0.append((from, to)) }
                default:
                    break
                }
            }
        )

        var adapter = GossipV1StreamAdapter(
            engine: engine,
            clock: FixedClock(nowMs: 0),
            store: InMemoryGossipStore(),
            isAuthenticatedRelayTransport: { false },
            hooks: hooks
        )

        let validFirst = try GossipV1TestSupport.fixtureData("hello.cbor")
        let invalidSecond = Data([0x00, 0x00, 0x00, 0x00]) // empty frame_len
        let streamBytes = try GossipV1Framing.encodeStreamFrame(validFirst) + invalidSecond

        try adapter.receiveBytes(streamBytes)

        // The first valid frame must not be dropped.
        XCTAssertEqual(receivedFrames.withLock { $0 }.count, 1)

        // Boundary error is fatal: we should terminate.
        // (The first frame is a valid HELLO, so we may have already transitioned to `.active`.)
        let transitions = stateTransitions.withLock { $0 }
        XCTAssertTrue(transitions.contains { _, to in
            to == .terminated(reason: .protocolViolation("stream boundary"))
        })

        let errs = errors.withLock { $0 }
        XCTAssertEqual(errs, [.streamBoundary(.emptyFrame)])
    }

    func testReceiveBytes_twoFramesInOneBuffer_firstValidSecondInvalidEnvelope_fatalStopsProcessing_butDoesNotDropFirstFrame() throws {
        let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
        let engine = GossipV1EncounterEngine(config: .init(localHello: localHello))

        let receivedFrames = Locked<[GossipV1Frame]>([])
        let errors = Locked<[GossipV1TransportError]>([])
        let stateTransitions = Locked<[(GossipV1EncounterEngine.State, GossipV1EncounterEngine.State)]>([])
        let hooks = GossipV1StreamAdapter.Hooks(
            onSend: { _ in },
            onEvent: { event in
                switch event {
                case .didReceiveFrame(let frame):
                    receivedFrames.withLock { $0.append(frame) }
                case .didEncounterError(let err):
                    errors.withLock { $0.append(err) }
                case .didChangeState(from: let from, to: let to):
                    stateTransitions.withLock { $0.append((from, to)) }
                default:
                    break
                }
            }
        )

        var adapter = GossipV1StreamAdapter(
            engine: engine,
            clock: FixedClock(nowMs: 0),
            store: InMemoryGossipStore(),
            isAuthenticatedRelayTransport: { false },
            hooks: hooks
        )

        let validFirst = try GossipV1TestSupport.fixtureData("hello.cbor")
        // Valid canonical CBOR, invalid envelope shape.
        let invalidEnvelope = try CanonicalCBOREncoder().encode(.unsigned(1))
        let trailing = try GossipV1TestSupport.fixtureData("hello.cbor")
        let streamBytes = try GossipV1Framing.encodeStreamFrame(validFirst)
            + GossipV1Framing.encodeStreamFrame(invalidEnvelope)
            + GossipV1Framing.encodeStreamFrame(trailing)

        try adapter.receiveBytes(streamBytes)

        // First frame must not be dropped. The invalid envelope is a decode failure (no frame
        // emitted) and is fatal; subsequent frames in the same buffer must not be processed.
        XCTAssertEqual(receivedFrames.withLock { $0 }.count, 1)

        XCTAssertTrue(stateTransitions.withLock { $0 }.contains { _, to in
            to == .terminated(reason: .protocolViolation("invalid frame envelope"))
        })

        XCTAssertTrue(errors.withLock { $0 }.contains(.invalidFrame(.envelopeNotAMap)))
    }

    func testReceiveBytes_fatalTransferValidationTerminates_andStopsProcessingSubsequentFrames() throws {
        let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION, maxTransfer: 16)
        let engine = GossipV1EncounterEngine(config: .init(localHello: localHello))

        let errors = Locked<[GossipV1TransportError]>([])
        let transitions = Locked<[(GossipV1EncounterEngine.State, GossipV1EncounterEngine.State)]>([])
        let receivedFrames = Locked<[GossipV1Frame]>([])
        let hooks = GossipV1StreamAdapter.Hooks(
            onSend: { _ in },
            onEvent: { event in
                switch event {
                case .didEncounterError(let err):
                    errors.withLock { $0.append(err) }
                case .didChangeState(from: let from, to: let to):
                    transitions.withLock { $0.append((from, to)) }
                case .didReceiveFrame(let frame):
                    receivedFrames.withLock { $0.append(frame) }
                default:
                    break
                }
            }
        )

        var adapter = GossipV1StreamAdapter(
            engine: engine,
            clock: FixedClock(nowMs: 0),
            store: InMemoryGossipStore(),
            isAuthenticatedRelayTransport: { false },
            hooks: hooks
        )

        // Establish active state.
        let helloBytes = try GossipV1TestSupport.fixtureData("hello.cbor")
        try adapter.receiveBytes(try GossipV1Framing.encodeStreamFrame(helloBytes))
        XCTAssertEqual(adapter.state, .active)

        // Create an inbound TRANSFER that violates local max_transfer (16) by having 17 objects.
        let expiry: UInt64 = 4_102_444_800_000
        let objs: [GossipV1TransferFrame.Object] = try (0..<17).map { i in
            let envBytes = try CanonicalCBOREncoder().encode(.map([.init(key: .text("x"), value: .unsigned(UInt64(i)))]))
            let id = GossipV1ItemID.derive(fromEnvelopeBytes: envBytes)
            return try GossipV1TransferFrame.Object(itemID: id, envelopeBytes: envBytes, expiryUnixMs: expiry, hopCount: 0)
        }
        let tooMany = try GossipV1TransferFrame(objects: objs)

        let streamBytes = try GossipV1Framing.encodeStreamFrame(GossipV1Frame.transfer(tooMany).encode())
            + GossipV1Framing.encodeStreamFrame(helloBytes)

        try adapter.receiveBytes(streamBytes)

        XCTAssertEqual(adapter.state, .terminated(reason: .protocolViolation("transfer validation")))

        // Ensure subsequent frames in the same buffer are not processed.
        XCTAssertEqual(receivedFrames.withLock { $0 }.count, 2)

        XCTAssertTrue(errors.withLock { $0 }.contains(.encounterValidation(.transferTooManyObjects(max: 16, actual: 17))))
        XCTAssertTrue(transitions.withLock { $0 }.contains { _, to in
            to == .terminated(reason: .protocolViolation("transfer validation"))
        })
    }

    func testFinish_withTruncatedFrame_isFatalStreamBoundary_andEmitsStateChangeBeforeError() throws {
        let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
        let engine = GossipV1EncounterEngine(config: .init(localHello: localHello))

        let events = Locked<[GossipV1StreamAdapter.Event]>([])
        let hooks = GossipV1StreamAdapter.Hooks(
            onSend: { _ in },
            onEvent: { event in
                events.withLock { $0.append(event) }
            }
        )

        var adapter = GossipV1StreamAdapter(
            engine: engine,
            clock: FixedClock(nowMs: 0),
            store: InMemoryGossipStore(),
            isAuthenticatedRelayTransport: { false },
            hooks: hooks
        )

        // Establish active state so termination is observable as a transition.
        let helloBytes = try GossipV1TestSupport.fixtureData("hello.cbor")
        try adapter.receiveBytes(try GossipV1Framing.encodeStreamFrame(helloBytes))

        // Append an incomplete (truncated) stream frame: u32be length for 2 bytes payload,
        // but only provide 1 payload byte.
        let frameBytes = Data([0xAB, 0xCD])
        let full = try GossipV1Framing.encodeStreamFrame(frameBytes)
        try adapter.receiveBytes(full.dropLast(1))

        // Finish should surface a fatal boundary error and terminate.
        try adapter.finish()

        let snapshot = events.withLock { $0 }
        let stateIdx = snapshot.firstIndex { if case .didChangeState = $0 { true } else { false } }
        let errorIdx = snapshot.firstIndex { if case .didEncounterError = $0 { true } else { false } }
        XCTAssertNotNil(stateIdx)
        XCTAssertNotNil(errorIdx)
        XCTAssertLessThan(stateIdx!, errorIdx!)

        let errorEvents = snapshot.compactMap { event -> GossipV1TransportError? in
            guard case .didEncounterError(let err) = event else { return nil }
            return err
        }
        XCTAssertTrue(errorEvents.contains(.streamBoundary(.truncated)))
    }

    func testReceiveBytes_transferMixedValidity_emitsAcceptForValidItemIDs_andErrorForInvalidObject_andDoesNotTerminate() throws {
        let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
        let engine = GossipV1EncounterEngine(config: .init(localHello: localHello))

        let events = Locked<[GossipV1StreamAdapter.Event]>([])
        let hooks = GossipV1StreamAdapter.Hooks(
            onSend: { _ in },
            onEvent: { event in
                events.withLock { $0.append(event) }
            }
        )

        var adapter = GossipV1StreamAdapter(
            engine: engine,
            clock: FixedClock(nowMs: 1_000),
            store: InMemoryGossipStore(),
            isAuthenticatedRelayTransport: { false },
            hooks: hooks
        )

        // Activate encounter.
        let helloBytes = try GossipV1TestSupport.fixtureData("hello.cbor")
        try adapter.receiveBytes(try GossipV1Framing.encodeStreamFrame(helloBytes))
        XCTAssertEqual(adapter.state, .active)

        // Build a mixed-validity TRANSFER: [valid, expired, valid].
        let expiryOk: UInt64 = 1_000 + GossipV1.CLOCK_SKEW_TOLERANCE_MS + 1
        let expiryExpired: UInt64 = 1_000 + GossipV1.CLOCK_SKEW_TOLERANCE_MS

        func makeObject(x: UInt64, expiry: UInt64) throws -> GossipV1TransferFrame.Object {
            let envBytes = try CanonicalCBOREncoder().encode(.map([.init(key: .text("x"), value: .unsigned(x))]))
            let id = GossipV1ItemID.derive(fromEnvelopeBytes: envBytes)
            return try GossipV1TransferFrame.Object(itemID: id, envelopeBytes: envBytes, expiryUnixMs: expiry, hopCount: 0)
        }

        let a = try makeObject(x: 1, expiry: expiryOk)
        let bExpired = try makeObject(x: 2, expiry: expiryExpired)
        let c = try makeObject(x: 3, expiry: expiryOk)
        let transfer = GossipV1TransferFrame(unsafeObjects: [a, bExpired, c])

        try adapter.receiveBytes(try GossipV1Framing.encodeStreamFrame(GossipV1Frame.transfer(transfer).encode()))

        // Encounter must remain active.
        XCTAssertEqual(adapter.state, .active)

        let snapshot = events.withLock { $0 }

        // Must accept the valid IDs.
        let accepted = snapshot.compactMap { event -> [GossipV1ItemID]? in
            guard case .didAcceptTransfer(itemIDs: let ids) = event else { return nil }
            return ids
        }
        XCTAssertEqual(accepted.flatMap { $0 }, [a.itemID, c.itemID])

        let acceptedReceipts = snapshot.compactMap { event -> [GossipV1ItemID]? in
            guard case .didAcceptReceipt(itemIDs: let ids) = event else { return nil }
            return ids
        }
        XCTAssertTrue(acceptedReceipts.isEmpty)

        // Must surface a non-fatal error for the expired object.
        let errors = snapshot.compactMap { event -> GossipV1TransportError? in
            guard case .didEncounterError(let err) = event else { return nil }
            return err
        }
        XCTAssertTrue(errors.contains(.encounterValidation(.transferExpired(nowUnixMs: 1_000, expiryUnixMs: expiryExpired))))

        // Must NOT emit termination.
        XCTAssertFalse(snapshot.contains { event in
            if case .didChangeState(_, .terminated) = event { return true }
            return false
        })
    }

    func testReceiveBytes_receiptEventEmittedOnlyWhenReceiptAccepted_notWhenOnlyObserved() throws {
        let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
        let engine = GossipV1EncounterEngine(config: .init(localHello: localHello))

        let envelopeBytes = try CanonicalCBOREncoder().encode(.map([.init(key: .text("x"), value: .unsigned(42))]))
        let itemID = GossipV1ItemID.derive(fromEnvelopeBytes: envelopeBytes)
        let store = RequestServingStore(
            itemID: itemID,
            envelopeBytes: envelopeBytes,
            expiryUnixMs: 4_102_444_800_000,
            hopCount: 0
        )

        let events = Locked<[GossipV1StreamAdapter.Event]>([])
        let hooks = GossipV1StreamAdapter.Hooks(
            onSend: { _ in },
            onEvent: { event in
                events.withLock { $0.append(event) }
            }
        )

        var adapter = GossipV1StreamAdapter(
            engine: engine,
            clock: FixedClock(nowMs: 1_000),
            store: store,
            isAuthenticatedRelayTransport: { false },
            hooks: hooks
        )

        let helloBytes = try GossipV1TestSupport.fixtureData("hello.cbor")
        try adapter.receiveBytes(try GossipV1Framing.encodeStreamFrame(helloBytes))

        let request = try GossipV1RequestFrame(want: [itemID])
        try adapter.receiveBytes(try GossipV1Framing.encodeStreamFrame(GossipV1Frame.request(request).encode()))

        let receipt = try GossipV1ReceiptFrame(received: [itemID])
        let receiptBytes = try GossipV1Framing.encodeStreamFrame(GossipV1Frame.receipt(receipt).encode())

        // First RECEIPT is accepted.
        try adapter.receiveBytes(receiptBytes)
        // Second RECEIPT is only observed and rejected (no immediately preceding outbound TRANSFER).
        try adapter.receiveBytes(receiptBytes)

        let snapshot = events.withLock { $0 }

        let observedReceipts = snapshot.compactMap { event -> GossipV1Frame? in
            guard case .didReceiveFrame(.receipt(let frame)) = event else { return nil }
            return .receipt(frame)
        }
        XCTAssertEqual(observedReceipts.count, 2)

        let acceptedReceipts = snapshot.compactMap { event -> [GossipV1ItemID]? in
            guard case .didAcceptReceipt(itemIDs: let ids) = event else { return nil }
            return ids
        }
        XCTAssertEqual(acceptedReceipts, [[itemID]])

        XCTAssertTrue(snapshot.contains { event in
            if case .didEncounterError(.encounterValidation(.receiptWithoutPrecedingTransfer)) = event { return true }
            return false
        })
    }

}

// MARK: - Minimal test helpers (scoped to this file)

private func makeHello(version: UInt64, maxWant: UInt64 = 128, maxTransfer: UInt64 = 16) throws -> GossipV1HelloFrame {
    let pubKey = Data(repeating: 0x01, count: 32)
    let nodeID = GossipV1NodeID.derive(fromPublicKeyRawBytes: pubKey)
    return try GossipV1HelloFrame(
        version: version,
        nodeID: nodeID,
        nodePublicKeyRawBytes: pubKey,
        capabilities: ["store"],
        propagationClass: "direct",
        maxWant: maxWant,
        maxTransfer: maxTransfer
    )
}

private struct FixedClock: GossipV1EncounterEngine.Clock {
    let nowMs: UInt64
    func nowUnixMs() -> UInt64 { nowMs }
}

private final class InMemoryGossipStore: @unchecked Sendable, GossipV1EncounterEngine.Store {
    func eligibleItemIDs(nowMs _: UInt64) throws -> [GossipV1ItemID] { [] }
    func fetch(_: GossipV1ItemID) throws -> (envelopeBytes: Data, expiryUnixMs: UInt64, hopCount: UInt16)? { nil }
    func existingHopCount(_: GossipV1ItemID) throws -> UInt16? { nil }
    func ingest(_: GossipV1ItemID, envelopeBytes _: Data, expiryUnixMs _: UInt64, hopCount _: UInt16) throws {}
}

private final class RequestServingStore: @unchecked Sendable, GossipV1EncounterEngine.Store {
    private let itemID: GossipV1ItemID
    private let envelopeBytes: Data
    private let expiryUnixMs: UInt64
    private let hopCount: UInt16

    init(itemID: GossipV1ItemID, envelopeBytes: Data, expiryUnixMs: UInt64, hopCount: UInt16) {
        self.itemID = itemID
        self.envelopeBytes = envelopeBytes
        self.expiryUnixMs = expiryUnixMs
        self.hopCount = hopCount
    }

    func eligibleItemIDs(nowMs _: UInt64) throws -> [GossipV1ItemID] { [itemID] }

    func fetch(_ itemID: GossipV1ItemID) throws -> (envelopeBytes: Data, expiryUnixMs: UInt64, hopCount: UInt16)? {
        guard itemID == self.itemID else { return nil }
        return (envelopeBytes: envelopeBytes, expiryUnixMs: expiryUnixMs, hopCount: hopCount)
    }

    func existingHopCount(_: GossipV1ItemID) throws -> UInt16? { nil }

    func ingest(_: GossipV1ItemID, envelopeBytes _: Data, expiryUnixMs _: UInt64, hopCount _: UInt16) throws {}
}

private final class CancellationThrowingRelayObserver: @unchecked Sendable, GossipV1EncounterEngine.RelayIngestObserving {
    func noteAuthenticatedRelayIngest(itemIDs _: [GossipV1ItemID], nowMs _: UInt64) throws {
        throw CancellationError()
    }
}

private final class RelayIngestValidationErrorSeamObserver: @unchecked Sendable, GossipV1EncounterEngine.RelayIngestObserving {
    let error: GossipV1EncounterEngine.ValidationError

    init(error: GossipV1EncounterEngine.ValidationError) {
        self.error = error
    }

    func noteAuthenticatedRelayIngest(itemIDs _: [GossipV1ItemID], nowMs _: UInt64) throws {
        throw error
    }
}

private struct FixtureError: Swift.Error, Equatable {}

private final class ThrowingRelayObserver: @unchecked Sendable, GossipV1EncounterEngine.RelayIngestObserving {
    let error: any Swift.Error

    init(error: any Swift.Error) {
        self.error = error
    }

    func noteAuthenticatedRelayIngest(itemIDs _: [GossipV1ItemID], nowMs _: UInt64) throws {
        throw error
    }
}
