import Foundation
import Testing
@testable import AethosCore

@Test
func gossipV1_loopback_adapterInterop_helloRoundTrip_bothHealthy() throws {
    let helloA = try gossipV1_makeHello(pubKeyByte: 0xA1)
    let helloB = try gossipV1_makeHello(pubKeyByte: 0xB2)

    let clock = GossipV1FixedClock(nowMs: 0)
    let storeA = GossipV1InMemoryStore()
    let storeB = GossipV1InMemoryStore()

    let endpointA = GossipV1LoopbackHarness.Endpoint(
        engine: GossipV1EncounterEngine(config: .init(localHello: helloA)),
        clock: clock,
        store: storeA,
        relayIngest: .init(observer: nil, isAuthenticatedTransport: { false })
    )
    let endpointB = GossipV1LoopbackHarness.Endpoint(
        engine: GossipV1EncounterEngine(config: .init(localHello: helloB)),
        clock: clock,
        store: storeB,
        relayIngest: .init(observer: nil, isAuthenticatedTransport: { false })
    )

    let harness = GossipV1LoopbackHarness(a: endpointA, b: endpointB)

    endpointA.sendHello()
    endpointB.sendHello()
    harness.pumpUntilIdle()

    #expect(endpointA.state == .active)
    #expect(endpointB.state == .active)

    let aHelloReceiveCount = endpointA.events.filter { if case .didReceiveFrame(.hello) = $0 { true } else { false } }.count
    let bHelloReceiveCount = endpointB.events.filter { if case .didReceiveFrame(.hello) = $0 { true } else { false } }.count
    #expect(aHelloReceiveCount == 1)
    #expect(bHelloReceiveCount == 1)
}

@Test
func gossipV1_loopback_adapterInterop_fullEncounter_happyPath_summary_request_transfer_receipt_dedupeByItemID() throws {
    let helloA = try gossipV1_makeHello(pubKeyByte: 0xA1)
    let helloB = try gossipV1_makeHello(pubKeyByte: 0xB2)
    let clock = GossipV1FixedClock(nowMs: 1_000)

    let storeA = GossipV1InMemoryStore()
    let storeB = GossipV1InMemoryStore()

    // A has one eligible object; B starts empty.
    let expiry: UInt64 = 4_102_444_800_000
    let envBytes = try CanonicalCBOREncoder().encode(.map([.init(key: .text("x"), value: .unsigned(42))]))
    let itemID = GossipV1ItemID.derive(fromEnvelopeBytes: envBytes)
    storeA.put(itemID: itemID, envelopeBytes: envBytes, expiryUnixMs: expiry, hopCount: 0)
    storeA.setEligible([itemID])

    let endpointA = GossipV1LoopbackHarness.Endpoint(
        engine: GossipV1EncounterEngine(config: .init(localHello: helloA)),
        clock: clock,
        store: storeA,
        relayIngest: .init(observer: nil, isAuthenticatedTransport: { false })
    )
    let endpointB = GossipV1LoopbackHarness.Endpoint(
        engine: GossipV1EncounterEngine(config: .init(localHello: helloB)),
        clock: clock,
        store: storeB,
        relayIngest: .init(observer: nil, isAuthenticatedTransport: { false })
    )
    let harness = GossipV1LoopbackHarness(a: endpointA, b: endpointB)

    // HELLO exchange.
    endpointA.sendHello()
    endpointB.sendHello()
    harness.pumpUntilIdle()
    #expect(endpointA.state == .active)
    #expect(endpointB.state == .active)

    let aHelloReceiveCount = endpointA.events.filter { if case .didReceiveFrame(.hello) = $0 { true } else { false } }.count
    let bHelloReceiveCount = endpointB.events.filter { if case .didReceiveFrame(.hello) = $0 { true } else { false } }.count
    #expect(aHelloReceiveCount == 1)
    #expect(bHelloReceiveCount == 1)

    // SUMMARY: emitted by A; B should accept/observe but this engine does not reply.
    // Assert bloom bytes are deterministic for A's eligible set.
    let expectedBloom = GossipV1BloomFilter.build(for: [itemID])
    let summary = try GossipV1SummaryFrame(bloomFilter: expectedBloom, itemCount: 1)
    endpointA.sendFrame(.summary(summary))
    harness.pumpUntilIdle()

    let summaryReceives = endpointB.events.compactMap { event -> GossipV1SummaryFrame? in
        guard case .didReceiveFrame(.summary(let s)) = event else { return nil }
        return s
    }
    #expect(summaryReceives.count == 1)
    #expect(summaryReceives.first?.itemCount == 1)
    #expect(summaryReceives.first?.bloomFilter == expectedBloom)

    // REQUEST: B asks for A's item.
    // The inbound REQUEST cap is the peer's HELLO `max_want`, so ensure A advertises >= 1.
    endpointB.sendFrame(.request(try GossipV1RequestFrame(want: [itemID])))
    harness.pumpUntilIdle()

    let sentRequestsFromB = endpointB.events.compactMap { event -> GossipV1RequestFrame? in
        guard case .didSendFrame(.request(let r)) = event else { return nil }
        return r
    }
    #expect(sentRequestsFromB.count == 1)
    #expect(sentRequestsFromB.first?.want == [itemID])

    // A must respond with TRANSFER for requested id.
    let receiveRequestIndexOnA = endpointA.events.firstIndex { event in
        guard case .didReceiveFrame(.request(let r)) = event else { return false }
        return r.want == [itemID]
    }
    let sendTransferIndexOnA = endpointA.events.firstIndex { event in
        guard case .didSendFrame(.transfer(let t)) = event else { return false }
        return t.objects.map(\.itemID) == [itemID]
    }
    #expect(receiveRequestIndexOnA != nil)
    #expect(sendTransferIndexOnA != nil)
    #expect(receiveRequestIndexOnA! < sendTransferIndexOnA!)

    // B must accept transfer, ingest it, and send receipt scoped to last transfer.
    let receiveTransferIndexOnB = endpointB.events.firstIndex { event in
        guard case .didReceiveFrame(.transfer(let t)) = event else { return false }
        return t.objects.map(\.itemID) == [itemID]
    }
    let acceptTransferIndexOnB = endpointB.events.firstIndex { event in
        guard case .didAcceptTransfer(let ids) = event else { return false }
        return ids == [itemID]
    }
    #expect(receiveTransferIndexOnB != nil)
    #expect(acceptTransferIndexOnB != nil)
    #expect(receiveTransferIndexOnB! < acceptTransferIndexOnB!)

    #expect(storeB.entry(itemID) != nil)
    #expect(storeB.entry(itemID)?.envelopeBytes == envBytes)
    #expect(storeB.entry(itemID)?.hopCount == 1)

    let sendReceiptIndexOnB = endpointB.events.firstIndex { event in
        guard case .didSendFrame(.receipt(let r)) = event else { return false }
        return r.received == [itemID]
    }
    #expect(sendReceiptIndexOnB != nil)
    #expect(acceptTransferIndexOnB! < sendReceiptIndexOnB!)

    // Dedupe by item_id inside a transfer: duplicate ids must be rejected and not affect store.
    let obj = try GossipV1TransferFrame.Object(itemID: itemID, envelopeBytes: envBytes, expiryUnixMs: expiry, hopCount: 1)
    #expect(throws: GossipV1FrameError.duplicateItemID) {
        _ = try GossipV1TransferFrame(objects: [obj, obj])
    }
}

@Test
func gossipV1_loopback_adapterInterop_idempotency_sameObjectTransferredAgain_noDuplicateImport_converges() throws {
    let helloA = try gossipV1_makeHello(pubKeyByte: 0xA1)
    let helloB = try gossipV1_makeHello(pubKeyByte: 0xB2)
    let clock = GossipV1FixedClock(nowMs: 1_000)

    let storeA = GossipV1InMemoryStore()
    let storeB = GossipV1InMemoryStore()

    let expiry: UInt64 = 4_102_444_800_000
    let envBytes = try CanonicalCBOREncoder().encode(.map([.init(key: .text("x"), value: .unsigned(1))]))
    let itemID = GossipV1ItemID.derive(fromEnvelopeBytes: envBytes)
    storeA.put(itemID: itemID, envelopeBytes: envBytes, expiryUnixMs: expiry, hopCount: 0)

    let endpointA = GossipV1LoopbackHarness.Endpoint(
        engine: GossipV1EncounterEngine(config: .init(localHello: helloA)),
        clock: clock,
        store: storeA,
        relayIngest: .init(observer: nil, isAuthenticatedTransport: { false })
    )
    let endpointB = GossipV1LoopbackHarness.Endpoint(
        engine: GossipV1EncounterEngine(config: .init(localHello: helloB)),
        clock: clock,
        store: storeB,
        relayIngest: .init(observer: nil, isAuthenticatedTransport: { false })
    )
    let harness = GossipV1LoopbackHarness(a: endpointA, b: endpointB)

    endpointA.sendHello(); endpointB.sendHello(); harness.pumpUntilIdle()

    // First request/transfer/receipt.
    endpointB.sendFrame(.request(try GossipV1RequestFrame(want: [itemID])))
    harness.pumpUntilIdle()

    #expect(storeB.entry(itemID) != nil)
    let firstIngestCalls = storeB.ingestCallsByID[itemID] ?? 0
    #expect(firstIngestCalls == 1)
    #expect(storeB.firstTimeIngested.count == 1)

    // Request again; store should treat as idempotent (equal hop allowed).
    endpointB.sendFrame(.request(try GossipV1RequestFrame(want: [itemID])))
    harness.pumpUntilIdle()

    let secondIngestCalls = storeB.ingestCallsByID[itemID] ?? 0
    #expect(secondIngestCalls == 2)
    #expect(storeB.firstTimeIngested.count == 1)
    #expect(storeB.entry(itemID)?.hopCount == 1)
}

@Test
func gossipV1_loopback_adapterInterop_versionMismatch_failClosed_noFurtherFramesProcessed_stateChangePrecedesError() throws {
    let helloA = try gossipV1_makeHello(pubKeyByte: 0xA1)
    let helloB = try gossipV1_makeHello(pubKeyByte: 0xB2)
    let clock = GossipV1FixedClock(nowMs: 0)

    let storeA = GossipV1InMemoryStore()
    let storeB = GossipV1InMemoryStore()

    let endpointA = GossipV1LoopbackHarness.Endpoint(
        engine: GossipV1EncounterEngine(config: .init(localHello: helloA)),
        clock: clock,
        store: storeA,
        relayIngest: .init(observer: nil, isAuthenticatedTransport: { false })
    )
    let endpointB = GossipV1LoopbackHarness.Endpoint(
        engine: GossipV1EncounterEngine(config: .init(localHello: helloB)),
        clock: clock,
        store: storeB,
        relayIngest: .init(observer: nil, isAuthenticatedTransport: { false })
    )
    let harness = GossipV1LoopbackHarness(a: endpointA, b: endpointB)

    endpointA.sendHello()
    endpointB.sendHello()
    harness.pumpUntilIdle()
    #expect(endpointA.state == .active)
    #expect(endpointB.state == .active)

    // Craft a mismatched-version HELLO at CBOR level so frame decoding succeeds.
    let pubKey = Data(repeating: 0xCC, count: 32)
    let nodeID = GossipV1NodeID.derive(fromPublicKeyRawBytes: pubKey)
    let payload: CanonicalCBORValue = .map([
        .init(key: .text("version"), value: .unsigned(GossipV1.GOSSIP_VERSION + 1)),
        .init(key: .text("node_id"), value: .text(nodeID.hex)),
        .init(key: .text("node_pubkey"), value: .text(GossipV1Base64URL.encode(pubKey))),
        .init(key: .text("capabilities"), value: .array([.text("store")])) ,
        .init(key: .text("propagation_class"), value: .text("direct")),
        .init(key: .text("max_want"), value: .unsigned(128)),
        .init(key: .text("max_transfer"), value: .unsigned(16)),
    ])
    let env: CanonicalCBORValue = .map([
        .init(key: .text("type"), value: .text(GossipV1FrameType.HELLO.rawValue)),
        .init(key: .text("payload"), value: payload),
    ])
    let badHelloDatagram = try CanonicalCBOREncoder().encode(env)
    let badHelloStreamBytes = try GossipV1Framing.encodeStreamFrame(badHelloDatagram)
    endpointB.receiveBytes(badHelloStreamBytes)

    // Endpoint B must terminate; ordering guarantee: state change to .terminated precedes error.
    #expect({ if case .terminated = endpointB.state { true } else { false } }())
    let terminationIndex = endpointB.events.firstIndex { event in
        guard case .didChangeState(_, .terminated) = event else { return false }
        return true
    }
    let errorIndex = endpointB.events.firstIndex { event in
        guard case .didEncounterError(.encounterValidation(.invalidHelloVersion(expected: _, actual: _))) = event else { return false }
        return true
    }
    #expect(terminationIndex != nil)
    #expect(errorIndex != nil)
    #expect(terminationIndex! < errorIndex!)

    // After termination, additional frames must be ignored (no didReceiveFrame beyond the bad HELLO).
    let didReceiveCount = endpointB.events.filter { if case .didReceiveFrame = $0 { true } else { false } }.count
    endpointA.sendFrame(.summary(try GossipV1SummaryFrame(bloomFilter: Data(repeating: 0, count: GossipV1.BLOOM_FILTER_BYTES), itemCount: 0)))
    harness.pumpUntilIdle()
    let didReceiveCountAfter = endpointB.events.filter { if case .didReceiveFrame = $0 { true } else { false } }.count
    #expect(didReceiveCountAfter == didReceiveCount)
}

@Test
func gossipV1_loopback_adapterInterop_invalidTransfer_rejected_noStoreEffect_nonFatalMatchesImplementation() throws {
    let helloA = try gossipV1_makeHello(pubKeyByte: 0xA1)
    let helloB = try gossipV1_makeHello(pubKeyByte: 0xB2)
    let clock = GossipV1FixedClock(nowMs: 1_000)
    let storeA = GossipV1InMemoryStore()
    let storeB = GossipV1InMemoryStore()

    let endpointA = GossipV1LoopbackHarness.Endpoint(
        engine: GossipV1EncounterEngine(config: .init(localHello: helloA)),
        clock: clock,
        store: storeA,
        relayIngest: .init(observer: nil, isAuthenticatedTransport: { false })
    )
    let endpointB = GossipV1LoopbackHarness.Endpoint(
        engine: GossipV1EncounterEngine(config: .init(localHello: helloB)),
        clock: clock,
        store: storeB,
        relayIngest: .init(observer: nil, isAuthenticatedTransport: { false })
    )
    let harness = GossipV1LoopbackHarness(a: endpointA, b: endpointB)

    endpointA.sendHello(); endpointB.sendHello(); harness.pumpUntilIdle()
    #expect(endpointA.state == .active)
    #expect(endpointB.state == .active)

    // Expired transfer object should be rejected by engine.
    let envBytes = try CanonicalCBOREncoder().encode(.map([.init(key: .text("x"), value: .unsigned(9))]))
    let itemID = GossipV1ItemID.derive(fromEnvelopeBytes: envBytes)
    let expiryUnixMs = clock.nowMs + GossipV1.CLOCK_SKEW_TOLERANCE_MS // cutoff >= expiry rejects.
    let obj = try GossipV1TransferFrame.Object(itemID: itemID, envelopeBytes: envBytes, expiryUnixMs: expiryUnixMs, hopCount: 1)
    let transfer = GossipV1TransferFrame(unsafeObjects: [obj])

    endpointA.sendFrame(.transfer(transfer))
    harness.pumpUntilIdle()

    #expect(storeB.entry(itemID) == nil)
    // Current implementation surfaces this as a recoverable validation error (state remains active).
    #expect(endpointB.state == .active)
    #expect(endpointB.events.contains { event in
        guard case .didEncounterError(.encounterValidation(.transferExpired(nowUnixMs: _, expiryUnixMs: _))) = event else { return false }
        return true
    })
}

@Test
func gossipV1_loopback_adapterInterop_relayIngest_unauthenticated_decodedObservable_noAppEffects_noStoreEffects() throws {
    let helloA = try gossipV1_makeHello(pubKeyByte: 0xA1)
    let helloB = try gossipV1_makeHello(pubKeyByte: 0xB2)
    let clock = GossipV1FixedClock(nowMs: 123)
    let storeA = GossipV1InMemoryStore()
    let storeB = GossipV1InMemoryStore()

    let observer = GossipV1InMemoryRelayObserver()
    let endpointA = GossipV1LoopbackHarness.Endpoint(
        engine: GossipV1EncounterEngine(config: .init(localHello: helloA)),
        clock: clock,
        store: storeA,
        relayIngest: .init(observer: nil, isAuthenticatedTransport: { false })
    )
    let endpointB = GossipV1LoopbackHarness.Endpoint(
        engine: GossipV1EncounterEngine(config: .init(localHello: helloB)),
        clock: clock,
        store: storeB,
        relayIngest: .init(observer: observer, isAuthenticatedTransport: { false })
    )
    let harness = GossipV1LoopbackHarness(a: endpointA, b: endpointB)

    endpointA.sendHello(); endpointB.sendHello(); harness.pumpUntilIdle()

    let id = try GossipV1ItemID(bytes: Data(repeating: 0xAB, count: 32))
    let ingest = try GossipV1RelayIngestFrame(itemIDs: [id])
    endpointA.sendFrame(.relayIngest(ingest))
    harness.pumpUntilIdle()

    // Decoded and observable as raw frame event.
    #expect(endpointB.events.contains { event in
        guard case .didReceiveFrame(.relayIngest(let f)) = event else { return false }
        return f.itemIDs == [id]
    })
    // But no trusted application frame callback, and no observer call.
    #expect(!endpointB.applicationFrames.contains { if case .relayIngest = $0 { true } else { false } })
    #expect(observer.calls.isEmpty)
    #expect(storeB.entry(id) == nil)

    // No state change as a side effect.
    #expect(endpointB.state == .active)
}

@Test
func gossipV1_loopback_adapterInterop_relayIngest_authenticated_reachesObserver_observerFailureIsObservable_andNonFatal() throws {
    let helloA = try gossipV1_makeHello(pubKeyByte: 0xA1)
    let helloB = try gossipV1_makeHello(pubKeyByte: 0xB2)
    let clock = GossipV1FixedClock(nowMs: 777)

    let storeA = GossipV1InMemoryStore()
    let storeB = GossipV1InMemoryStore()
    let observer = GossipV1InMemoryRelayObserver()

    enum ObserverBoom: Swift.Error { case boom }
    observer.errorToThrow = ObserverBoom.boom

    let endpointA = GossipV1LoopbackHarness.Endpoint(
        engine: GossipV1EncounterEngine(config: .init(localHello: helloA)),
        clock: clock,
        store: storeA,
        relayIngest: .init(observer: nil, isAuthenticatedTransport: { true })
    )
    let endpointB = GossipV1LoopbackHarness.Endpoint(
        engine: GossipV1EncounterEngine(config: .init(localHello: helloB)),
        clock: clock,
        store: storeB,
        relayIngest: .init(observer: observer, isAuthenticatedTransport: { true })
    )
    let harness = GossipV1LoopbackHarness(a: endpointA, b: endpointB)

    endpointA.sendHello(); endpointB.sendHello(); harness.pumpUntilIdle()
    #expect(endpointB.state == .active)

    let id = try GossipV1ItemID(bytes: Data(repeating: 0xCD, count: 32))
    let ingest = try GossipV1RelayIngestFrame(itemIDs: [id])
    endpointA.sendFrame(.relayIngest(ingest))
    harness.pumpUntilIdle()

    // Authenticated path reaches trusted callback (applicationFrames), and observer is attempted.
    #expect(endpointB.applicationFrames.contains { frame in
        guard case .relayIngest(let f) = frame else { return false }
        return f.itemIDs == [id]
    })
    #expect(observer.attemptCount == 1)
    #expect(observer.calls.isEmpty)

    // Observer errors must be surfaced and non-fatal (do not pin exact error mapping).
    let didEncounterAnyError = endpointB.events.contains { event in
        if case .didEncounterError = event { return true }
        return false
    }
    #expect(didEncounterAnyError)
    #expect(endpointB.state == .active)

    // Subsequent relay ingest should still be processed.
    observer.errorToThrow = nil
    let id2 = try GossipV1ItemID(bytes: Data(repeating: 0xEF, count: 32))
    let ingest2 = try GossipV1RelayIngestFrame(itemIDs: [id2])
    endpointA.sendFrame(.relayIngest(ingest2))
    harness.pumpUntilIdle()

    #expect(observer.attemptCount == 2)
    #expect(observer.calls.count == 1)
    #expect(observer.calls.first?.itemIDs == [id2])
    #expect(observer.calls.first?.nowMs == clock.nowMs)
}

@Test
func gossipV1_loopback_adapterInterop_invalidTransfer_hopRegression_rejected_noStoreEffect_nonFatalMatchesImplementation() throws {
    let helloA = try gossipV1_makeHello(pubKeyByte: 0xA1)
    let helloB = try gossipV1_makeHello(pubKeyByte: 0xB2)
    let clock = GossipV1FixedClock(nowMs: 1_000)

    let storeA = GossipV1InMemoryStore()
    let storeB = GossipV1InMemoryStore()

    let endpointA = GossipV1LoopbackHarness.Endpoint(
        engine: GossipV1EncounterEngine(config: .init(localHello: helloA)),
        clock: clock,
        store: storeA,
        relayIngest: .init(observer: nil, isAuthenticatedTransport: { false })
    )
    let endpointB = GossipV1LoopbackHarness.Endpoint(
        engine: GossipV1EncounterEngine(config: .init(localHello: helloB)),
        clock: clock,
        store: storeB,
        relayIngest: .init(observer: nil, isAuthenticatedTransport: { false })
    )
    let harness = GossipV1LoopbackHarness(a: endpointA, b: endpointB)

    endpointA.sendHello(); endpointB.sendHello(); harness.pumpUntilIdle()
    #expect(endpointB.state == .active)

    let expiry: UInt64 = 4_102_444_800_000
    let envBytes = try CanonicalCBOREncoder().encode(.map([.init(key: .text("x"), value: .unsigned(99))]))
    let itemID = GossipV1ItemID.derive(fromEnvelopeBytes: envBytes)

    // Seed B with higher hop; incoming is lower => deterministic hop regression.
    storeB.put(itemID: itemID, envelopeBytes: envBytes, expiryUnixMs: expiry, hopCount: 10)

    let obj = try GossipV1TransferFrame.Object(itemID: itemID, envelopeBytes: envBytes, expiryUnixMs: expiry, hopCount: 9)
    let transfer = try GossipV1TransferFrame(objects: [obj])

    endpointA.sendFrame(.transfer(transfer))
    harness.pumpUntilIdle()

    // Store must remain unchanged.
    #expect(storeB.entry(itemID)?.hopCount == 10)
    // Hop regression is surfaced as validation error but encounter remains active.
    #expect(endpointB.state == .active)
    #expect(endpointB.events.contains { event in
        guard case .didEncounterError(.encounterValidation(.hopRegression(existing: 10, incoming: 9))) = event else { return false }
        return true
    })
}

@Test
func gossipV1_loopback_adapterInterop_partialEncounter_resume_requestAgain_converges_idempotently() throws {
    let helloA = try gossipV1_makeHello(pubKeyByte: 0xA1)
    let helloB = try gossipV1_makeHello(pubKeyByte: 0xB2)
    let clock = GossipV1FixedClock(nowMs: 1_000)

    let storeA = GossipV1InMemoryStore()
    let storeB = GossipV1InMemoryStore()

    // A has one transferable item.
    let expiry: UInt64 = 4_102_444_800_000
    let envBytes = try CanonicalCBOREncoder().encode(.map([.init(key: .text("x"), value: .unsigned(123))]))
    let itemID = GossipV1ItemID.derive(fromEnvelopeBytes: envBytes)
    storeA.put(itemID: itemID, envelopeBytes: envBytes, expiryUnixMs: expiry, hopCount: 0)
    storeA.setEligible([itemID])

    let endpointA = GossipV1LoopbackHarness.Endpoint(
        engine: GossipV1EncounterEngine(config: .init(localHello: helloA)),
        clock: clock,
        store: storeA,
        relayIngest: .init(observer: nil, isAuthenticatedTransport: { false })
    )
    let endpointB = GossipV1LoopbackHarness.Endpoint(
        engine: GossipV1EncounterEngine(config: .init(localHello: helloB)),
        clock: clock,
        store: storeB,
        relayIngest: .init(observer: nil, isAuthenticatedTransport: { false })
    )
    let harness = GossipV1LoopbackHarness(a: endpointA, b: endpointB)

    // HELLO exchange.
    endpointA.sendHello(); endpointB.sendHello(); harness.pumpUntilIdle()
    #expect(endpointA.state == .active)
    #expect(endpointB.state == .active)

    // B requests the item, but we only deliver B -> A (request reaches A); we do not deliver A -> B yet.
    endpointB.sendFrame(.request(try GossipV1RequestFrame(want: [itemID])))
    harness.pumpBtoAUntilIdle()

    // A should have produced a TRANSFER in outbound bytes.
    let aSentTransferCount = endpointA.events.filter { if case .didSendFrame(.transfer) = $0 { true } else { false } }.count
    #expect(aSentTransferCount == 1)
    #expect(storeB.entry(itemID) == nil)

    // "Resume": request again; engine must deterministically respond again.
    endpointB.sendFrame(.request(try GossipV1RequestFrame(want: [itemID])))
    harness.pumpBtoAUntilIdle()
    let aSentTransferCountAfter = endpointA.events.filter { if case .didSendFrame(.transfer) = $0 { true } else { false } }.count
    #expect(aSentTransferCountAfter == 2)

    // Now deliver A -> B bytes; B should ingest and converge.
    harness.pumpAtoBUntilIdle()
    #expect(storeB.entry(itemID) != nil)
    #expect(storeB.firstTimeIngested.contains(itemID))

    // Deliver any remaining receipts/transfers; system should settle.
    harness.pumpUntilIdle()

    // Already-imported item should not be "first-time" again.
    let firstTimeCount = storeB.firstTimeIngested.count
    endpointB.sendFrame(.request(try GossipV1RequestFrame(want: [itemID])))
    harness.pumpUntilIdle()
    #expect(storeB.firstTimeIngested.count == firstTimeCount)
}
