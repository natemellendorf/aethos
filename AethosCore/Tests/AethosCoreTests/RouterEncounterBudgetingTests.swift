import Foundation
import Testing
@testable import AethosCore

@Test
func blinkEncounterPrioritizesControlAndEndangeredSmallItems() throws {
    let store = try makeStore()
    let router = Router(store: store)
    let now = Date(timeIntervalSince1970: 10_000)
    let peerId = Data(repeating: 0xAA, count: 32)

    let receipt = ReceiptV1(envelopeId: Data(repeating: 0x11, count: 32), manifestId: Data(repeating: 0x22, count: 32), receivedAtUnixMs: 1, signature: Data())
    try store.enqueue(item: OutboxItem(id: Data([0x01]), kind: .receipt, payload: CanonicalEncoderV1.encode(receipt), enqueuedAt: now))

    let urgentMessage = MessageV1(createdAtUnixMs: Int64(now.timeIntervalSince1970 * 1000), authorWayfarerId: peerId, body: Data("ok".utf8))
    try store.enqueue(item: OutboxItem(
        id: Data([0x02]),
        kind: .message,
        payload: CanonicalEncoderV1.encode(urgentMessage),
        enqueuedAt: now,
        expiresAt: now.addingTimeInterval(10)
    ))

    try seedChunkTransfer(store: store, now: now, toWayfarerId: peerId, idSeed: 0x33)

    let context = EncounterSchedulingContext(
        budget: EncounterBudgetProfile(maxBytes: 20_000, maxItems: 20, estimatedDurationSeconds: 8),
        selectedBearer: "sim-link",
        remoteWayfarerId: peerId
    )
    let plan = try router.planNextEncounter(context: context, now: now)

    #expect(plan.encounterClass == .blink)
    #expect(plan.items.count >= 2)
    #expect(plan.items[0].priority == .receipt)
    #expect(plan.items[1].priority == .message)
}

@Test
func durableEncounterAllocatesCargoWithoutStarvingControl() throws {
    let store = try makeStore()
    let router = Router(store: store)
    let now = Date(timeIntervalSince1970: 20_000)
    let peerId = Data(repeating: 0x55, count: 32)

    let receipt = ReceiptV1(envelopeId: Data(repeating: 0x44, count: 32), manifestId: Data(repeating: 0x22, count: 32), receivedAtUnixMs: 1, signature: Data())
    try store.enqueue(item: OutboxItem(id: Data([0x10]), kind: .receipt, payload: CanonicalEncoderV1.encode(receipt), enqueuedAt: now))
    try seedChunkTransfer(store: store, now: now, toWayfarerId: peerId, idSeed: 0x60)

    let context = EncounterSchedulingContext(
        budget: EncounterBudgetProfile(maxBytes: 200_000, maxItems: 100, estimatedDurationSeconds: 240),
        selectedBearer: "sim-link",
        remoteWayfarerId: peerId
    )
    let plan = try router.planNextEncounter(context: context, now: now)

    #expect(plan.encounterClass == .durable)
    #expect(plan.items.contains { $0.priority == .receipt })
    #expect(plan.items.contains { if case .chunk = $0 { true } else { false } })
    #expect(plan.items.first?.priority == .receipt)
}

@Test
func transitEndangeredItemCanBeatDestinationMetadata() throws {
    let store = try makeStore()
    let router = Router(store: store)
    let now = Date(timeIntervalSince1970: 30_000)
    let remotePeerId = Data(repeating: 0x77, count: 32)
    let thirdPartyPeerId = Data(repeating: 0x88, count: 32)

    let manifestId = Data(repeating: 0x13, count: 32)
    let destinationEnvelope = EnvelopeV1(toWayfarerId: remotePeerId, manifestId: manifestId, body: Data([0x01]))
    let transitEnvelope = EnvelopeV1(toWayfarerId: thirdPartyPeerId, manifestId: Data(repeating: 0x14, count: 32), body: Data([0x02]))

    try store.enqueue(item: OutboxItem(
        id: Data([0x20]),
        kind: .envelope,
        payload: CanonicalEncoderV1.encode(destinationEnvelope),
        enqueuedAt: now
    ))
    try store.enqueue(item: OutboxItem(
        id: Data([0x21]),
        kind: .envelope,
        payload: CanonicalEncoderV1.encode(transitEnvelope),
        enqueuedAt: now,
        expiresAt: now.addingTimeInterval(15)
    ))

    let context = EncounterSchedulingContext(
        budget: EncounterBudgetProfile(maxBytes: 16_000, maxItems: 10, estimatedDurationSeconds: 20),
        selectedBearer: "sim-link",
        remoteWayfarerId: remotePeerId
    )
    let plan = try router.planNextEncounter(context: context, now: now)

    let firstEnvelope = plan.items.first { if case .envelope = $0 { true } else { false } }
    #expect(firstEnvelope != nil)
    if case let .envelope(firstBytes)? = firstEnvelope {
        #expect(firstBytes == CanonicalEncoderV1.encode(transitEnvelope))
    }
}

@Test
func explainabilityLogsCaptureDecisionBreakdownAndInterruptionResumeMarkers() throws {
    let store = try makeStore()
    let router = Router(store: store)
    let now = Date(timeIntervalSince1970: 40_000)
    let peerId = Data(repeating: 0x99, count: 32)

    try seedChunkTransfer(store: store, now: now, toWayfarerId: peerId, idSeed: 0x40)

    let context = EncounterSchedulingContext(
        budget: EncounterBudgetProfile(maxBytes: 8_000, maxItems: 3, estimatedDurationSeconds: 2),
        selectedBearer: "sim-link",
        remoteWayfarerId: peerId,
        relayIngestSafetyAvailable: true
    )
    let plan = try router.planNextEncounter(context: context, now: now)

    #expect(!plan.decisionLogs.isEmpty)
    let selectedDecision = plan.decisionLogs.first { $0.chosenItemIdHex != nil }
    #expect(selectedDecision != nil)
    #expect(selectedDecision?.scoreBreakdown != nil)
    #expect(plan.decisionLogs.contains { $0.stopReason != nil })
    #expect(plan.decisionLogs.contains { $0.interruptionMarker == .resumeReady || $0.interruptionMarker == .interruptionDetected })
}

@Test
func encounterBudgetFixturesDriveExpectedEncounterClassesAndStops() throws {
    let fixtures = ["blink", "short", "durable"]
    for fixture in fixtures {
        let store = try makeStore()
        let router = Router(store: store)
        let now = Date(timeIntervalSince1970: 50_000)
        let peerId = Data(repeating: 0xA1, count: 32)

        let parsed = try loadFixture(named: fixture)
        #expect(parsed.maxBytes > 0)
        #expect(parsed.maxItems > 0)
        #expect(!parsed.expectedFocus.isEmpty)

        let receipt = ReceiptV1(envelopeId: Data(repeating: 0x41, count: 32), manifestId: Data(repeating: 0x51, count: 32), receivedAtUnixMs: 1, signature: Data())
        try store.enqueue(item: OutboxItem(id: Data([0x31]), kind: .receipt, payload: CanonicalEncoderV1.encode(receipt), enqueuedAt: now))
        try seedChunkTransfer(store: store, now: now, toWayfarerId: peerId, idSeed: 0x71)
        try seedChunkTransfer(store: store, now: now, toWayfarerId: peerId, idSeed: 0x72)
        try seedChunkTransfer(store: store, now: now, toWayfarerId: peerId, idSeed: 0x73)

        let context = EncounterSchedulingContext(
            budget: EncounterBudgetProfile(
                maxBytes: parsed.maxBytes,
                maxItems: parsed.maxItems,
                estimatedDurationSeconds: parsed.estimatedDurationSeconds
            ),
            selectedBearer: "sim-link",
            remoteWayfarerId: peerId
        )
        let plan = try router.planNextEncounter(context: context, now: now)
        #expect(plan.encounterClass.rawValue == parsed.name)
        #expect(plan.decisionLogs.last?.stopReason?.rawValue == parsed.stopReason)
        #expect(plan.items.contains { $0.priority == .receipt })
    }
}

@Test
func plannerIsDeterministicForSameInputsIncludingDecisionLogs() throws {
    let store = try makeStore()
    let router = Router(store: store)
    let now = Date(timeIntervalSince1970: 60_000)
    let peerId = Data(repeating: 0xD2, count: 32)

    let receipt = ReceiptV1(envelopeId: Data(repeating: 0x33, count: 32), manifestId: Data(repeating: 0x44, count: 32), receivedAtUnixMs: 1, signature: Data())
    try store.enqueue(item: OutboxItem(id: Data([0x90]), kind: .receipt, payload: CanonicalEncoderV1.encode(receipt), enqueuedAt: now))
    try seedChunkTransfer(store: store, now: now, toWayfarerId: peerId, idSeed: 0x91)

    let context = EncounterSchedulingContext(
        budget: EncounterBudgetProfile(maxBytes: 90_000, maxItems: 50, estimatedDurationSeconds: 45),
        selectedBearer: "sim-link",
        remoteWayfarerId: peerId
    )

    let planA = try router.planNextEncounter(context: context, now: now)
    let planB = try router.planNextEncounter(context: context, now: now)
    #expect(planA == planB)
}

@Test
func plannerContinuesAfterNonFittingCandidateToAvoidUnderfill() throws {
    let store = try makeStore()
    let router = Router(store: store)
    let now = Date(timeIntervalSince1970: 70_000)
    let peerId = Data(repeating: 0xE2, count: 32)

    let oversizedBody = Data(repeating: 0x41, count: 4_500)
    let oversizedMessage = MessageV1(createdAtUnixMs: Int64(now.timeIntervalSince1970 * 1000), authorWayfarerId: peerId, body: oversizedBody)
    let oversizedId = Data([0xA0])
    try store.enqueue(item: OutboxItem(
        id: oversizedId,
        kind: .message,
        payload: CanonicalEncoderV1.encode(oversizedMessage),
        enqueuedAt: now.addingTimeInterval(-3_000)
    ))

    let smallBody = Data(repeating: 0x42, count: 512)
    let smallMessage = MessageV1(createdAtUnixMs: Int64(now.timeIntervalSince1970 * 1000), authorWayfarerId: peerId, body: smallBody)
    let smallId = Data([0xA1])
    try store.enqueue(item: OutboxItem(
        id: smallId,
        kind: .message,
        payload: CanonicalEncoderV1.encode(smallMessage),
        enqueuedAt: now
    ))

    let context = EncounterSchedulingContext(
        budget: EncounterBudgetProfile(maxBytes: 1_500, maxItems: 10, estimatedDurationSeconds: 20),
        selectedBearer: "sim-link",
        remoteWayfarerId: peerId,
        userIntentBoostItemIDs: Set([oversizedId])
    )
    let plan = try router.planNextEncounter(context: context, now: now)

    #expect(plan.items.contains { if case let .message(bytes) = $0 { bytes == CanonicalEncoderV1.encode(smallMessage) } else { false } })
    #expect(!plan.items.contains { if case let .message(bytes) = $0 { bytes == CanonicalEncoderV1.encode(oversizedMessage) } else { false } })
}

@Test
func transitTierTwoRequiresEndangerment() throws {
    let store = try makeStore()
    let router = Router(store: store)
    let now = Date(timeIntervalSince1970: 75_000)
    let remotePeerId = Data(repeating: 0x61, count: 32)
    let thirdPartyPeerId = Data(repeating: 0x62, count: 32)

    let destinationEnvelope = EnvelopeV1(toWayfarerId: remotePeerId, manifestId: Data(repeating: 0x63, count: 32), body: Data([0x01]))
    let transitEnvelopeNotEndangered = EnvelopeV1(toWayfarerId: thirdPartyPeerId, manifestId: Data(repeating: 0x64, count: 32), body: Data([0x02]))

    try store.enqueue(item: OutboxItem(id: Data([0xD1]), kind: .envelope, payload: CanonicalEncoderV1.encode(destinationEnvelope), enqueuedAt: now))
    try store.enqueue(item: OutboxItem(
        id: Data([0xD2]),
        kind: .envelope,
        payload: CanonicalEncoderV1.encode(transitEnvelopeNotEndangered),
        enqueuedAt: now,
        expiresAt: now.addingTimeInterval(600)
    ))

    let plan = try router.planNextEncounter(
        context: EncounterSchedulingContext(
            budget: EncounterBudgetProfile(maxBytes: 16_000, maxItems: 10, estimatedDurationSeconds: 20),
            selectedBearer: "sim-link",
            remoteWayfarerId: remotePeerId
        ),
        now: now
    )

    let stopReasons = plan.decisionLogs.compactMap(\.stopReason)
    #expect(stopReasons.contains(.completedCandidates))
    let firstEnvelope = plan.items.first { if case .envelope = $0 { true } else { false } }
    if case let .envelope(firstBytes)? = firstEnvelope {
        #expect(firstBytes == CanonicalEncoderV1.encode(destinationEnvelope))
    }
}

@Test
func legacyPlanNextSessionPreservesPreEncounterDurableCapSemantics() throws {
    let store = try makeStore()
    let router = Router(store: store)
    let now = Date(timeIntervalSince1970: 80_000)
    let peerId = Data(repeating: 0xF2, count: 32)

    try seedChunkTransfer(store: store, now: now, toWayfarerId: peerId, idSeed: 0xB1)

    let legacyPlan = try router.planNextSession(budget: SessionBudget(maxBytes: 5_000, maxItems: 10), now: now)
    #expect(legacyPlan.contains { if case .chunk = $0 { true } else { false } })

    let encounterPlan = try router.planNextEncounter(
        context: EncounterSchedulingContext(
            budget: EncounterBudgetProfile(maxBytes: 5_000, maxItems: 10, estimatedDurationSeconds: nil),
            selectedBearer: "sim-link",
            remoteWayfarerId: peerId
        ),
        now: now
    )
    #expect(!encounterPlan.items.contains { if case .chunk = $0 { true } else { false } })
}

@Test
func explainabilityLogsDoNotLeakRawPayloadContent() throws {
    let store = try makeStore()
    let router = Router(store: store)
    let now = Date(timeIntervalSince1970: 90_000)
    let peerId = Data(repeating: 0xC2, count: 32)
    let secret = Data("super-secret-payload".utf8)
    let secretHex = Hex.encode(secret)

    let message = MessageV1(createdAtUnixMs: Int64(now.timeIntervalSince1970 * 1000), authorWayfarerId: peerId, body: secret)
    try store.enqueue(item: OutboxItem(id: Data([0xCC]), kind: .message, payload: CanonicalEncoderV1.encode(message), enqueuedAt: now))

    let plan = try router.planNextEncounter(
        context: EncounterSchedulingContext(
            budget: EncounterBudgetProfile(maxBytes: 30_000, maxItems: 10, estimatedDurationSeconds: 30),
            selectedBearer: "sim-link",
            remoteWayfarerId: peerId
        ),
        now: now
    )

    #expect(plan.decisionLogs.allSatisfy { log in
        let chosen = log.chosenItemIdHex ?? ""
        return chosen != secretHex && !chosen.contains("73757065722d736563726574")
    })
}

private struct EncounterBudgetFixture: Codable {
    let name: String
    let estimatedDurationSeconds: Double
    let maxBytes: Int
    let maxItems: Int
    let expectedFocus: [String]
    let stopReason: String

    private enum CodingKeys: String, CodingKey {
        case name
        case estimatedDurationSeconds = "estimated_duration_seconds"
        case maxBytes = "max_bytes"
        case maxItems = "max_items"
        case expectedFocus = "expected_focus"
        case stopReason = "stop_reason"
    }
}

private func makeStore() throws -> AethosStore {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
}

private func seedChunkTransfer(store: AethosStore, now: Date, toWayfarerId: Data, idSeed: UInt8) throws {
    let payload = Data(repeating: idSeed, count: Chunking.chunkSize + 5)
    let chunks = Chunking.chunk(payload)
    for chunk in chunks {
        try store.putChunk(id: chunk.id, bytes: chunk.bytes, receivedAt: now)
    }

    let manifest = Chunking.buildManifest(for: payload)
    let manifestBytes = CanonicalEncoderV1.encode(manifest)
    let manifestId = AethosIDs.manifestId(from: manifest)
    let envelope = EnvelopeV1(toWayfarerId: toWayfarerId, manifestId: manifestId, body: Data([idSeed]))
    let envelopeBytes = CanonicalEncoderV1.encode(envelope)

    try store.enqueue(item: OutboxItem(id: Data([idSeed, 0x01]), kind: .manifest, payload: manifestBytes, enqueuedAt: now))
    try store.enqueue(item: OutboxItem(id: Data([idSeed, 0x02]), kind: .envelope, payload: envelopeBytes, enqueuedAt: now))
}

private func loadFixture(named name: String) throws -> EncounterBudgetFixture {
    guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/encounter-budgeting") else {
        fatalError("missing fixture: \(name)")
    }
    let bytes = try Data(contentsOf: url)
    return try JSONDecoder().decode(EncounterBudgetFixture.self, from: bytes)
}
