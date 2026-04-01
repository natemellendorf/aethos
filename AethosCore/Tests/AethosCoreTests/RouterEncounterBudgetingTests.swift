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
        expiresAt: now.addingTimeInterval(45)
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
    #expect(plan.items[0].priority == CargoItem.Priority.receipt)
    #expect(plan.items.contains { $0.priority == CargoItem.Priority.message })
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
func transitEndangeredItemBeatsDestinationMetadataWhenOutsideClockSkewGuardBand() throws {
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
        expiresAt: now.addingTimeInterval(45)
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
            remoteWayfarerId: peerId,
            shadowMode: .compareLegacyFallbackV1,
            shadowTopN: 4
        )
        let plan = try router.planNextEncounter(context: context, now: now)
        #expect(plan.encounterClass.rawValue == parsed.name)
        #expect(plan.decisionLogs.last?.stopReason?.rawValue == parsed.stopReason)
        #expect(plan.items.contains { $0.priority == .receipt })
        let comparison = try #require(plan.shadowComparison)
        #expect(comparison.topN == 4)
        #expect(comparison.canonicalStopReason != nil)
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
func plannerStopsAtFirstNonFittingCandidatePerCanonicalPrefixRules() throws {
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

    #expect(!plan.items.contains { if case let .message(bytes) = $0 { bytes == CanonicalEncoderV1.encode(smallMessage) } else { false } })
    #expect(!plan.items.contains { if case let .message(bytes) = $0 { bytes == CanonicalEncoderV1.encode(oversizedMessage) } else { false } })
    #expect(plan.decisionLogs.compactMap(\.stopReason).contains(.maxBytesReached))
}

@Test
func transitTierTwoRequiresEndangerment() throws {
    let store = try makeStore()
    let router = Router(store: store)
    let now = Date(timeIntervalSince1970: 75_000)
    let remotePeerId = Data(repeating: 0x61, count: 32)
    let thirdPartyPeerId = Data(repeating: 0x62, count: 32)

    let destinationEnvelope = EnvelopeV1(toWayfarerId: remotePeerId, manifestId: Data(repeating: 0x63, count: 32), body: Data([0x01]))
    let transitEnvelopeEndangered = EnvelopeV1(toWayfarerId: thirdPartyPeerId, manifestId: Data(repeating: 0x65, count: 32), body: Data([0x03]))
    let transitEnvelopeNotEndangered = EnvelopeV1(toWayfarerId: thirdPartyPeerId, manifestId: Data(repeating: 0x64, count: 32), body: Data([0x02]))

    let destinationBytes = CanonicalEncoderV1.encode(destinationEnvelope)
    let endangeredBytes = CanonicalEncoderV1.encode(transitEnvelopeEndangered)
    let notEndangeredBytes = CanonicalEncoderV1.encode(transitEnvelopeNotEndangered)

    try store.enqueue(item: OutboxItem(id: Data([0xD1]), kind: .envelope, payload: destinationBytes, enqueuedAt: now))
    try store.enqueue(item: OutboxItem(
        id: Data([0xD3]),
        kind: .envelope,
        payload: endangeredBytes,
        enqueuedAt: now,
        expiresAt: now.addingTimeInterval(45)
    ))
    try store.enqueue(item: OutboxItem(
        id: Data([0xD2]),
        kind: .envelope,
        payload: notEndangeredBytes,
        enqueuedAt: now,
        expiresAt: now.addingTimeInterval(600)
    ))

    let plan = try router.planNextEncounter(
        context: EncounterSchedulingContext(
            budget: EncounterBudgetProfile(maxBytes: 16_000, maxItems: 2, estimatedDurationSeconds: 20),
            selectedBearer: "sim-link",
            remoteWayfarerId: remotePeerId
        ),
        now: now
    )

    let stopReasons = plan.decisionLogs.compactMap(\.stopReason)
    #expect(stopReasons.contains(.maxItemsReached))

    let selectedEnvelopePayloads = plan.items.compactMap { item -> Data? in
        if case let .envelope(bytes) = item { return bytes }
        return nil
    }

    // Explicit tier-semantics evidence:
    // - endangered transit envelope must be selected (tier 2)
    // - non-endangered transit envelope is not promoted to tier 2 (it may still be selected later as tier 3)
    #expect(selectedEnvelopePayloads.contains(endangeredBytes))
    #expect(selectedEnvelopePayloads.contains(notEndangeredBytes))

    let selectedIds = plan.decisionLogs.compactMap(\.chosenItemIdHex)
    #expect(selectedIds.first == Hex.encode(Data([0xD3])))
}

@Test
func sessionPlannerUsesCanonicalPrimaryAndPreservesChunkProgress() throws {
    let store = try makeStore()
    let router = Router(store: store)
    let now = Date(timeIntervalSince1970: 80_000)
    let peerId = Data(repeating: 0xF2, count: 32)

    try seedChunkTransfer(store: store, now: now, toWayfarerId: peerId, idSeed: 0xB1)

    let sessionPlan = try router.planNextSession(budget: SessionBudget(maxBytes: 5_000, maxItems: 10), now: now)
    #expect(sessionPlan.contains { if case .chunk = $0 { true } else { false } })

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

@Test
func shadowModeComparisonIncludesTelemetryForRepresentativeBlinkLane() throws {
    let store = try makeStore()
    let router = Router(store: store)
    let now = Date(timeIntervalSince1970: 100_000)
    let peerId = Data(repeating: 0xA9, count: 32)

    let receipt = ReceiptV1(
        envelopeId: Data(repeating: 0x12, count: 32),
        manifestId: Data(repeating: 0x34, count: 32),
        receivedAtUnixMs: 1,
        signature: Data()
    )
    try store.enqueue(item: OutboxItem(id: Data([0xE0]), kind: .receipt, payload: CanonicalEncoderV1.encode(receipt), enqueuedAt: now))

    let urgentMessage = MessageV1(createdAtUnixMs: Int64(now.timeIntervalSince1970 * 1000), authorWayfarerId: peerId, body: Data("blink".utf8))
    try store.enqueue(item: OutboxItem(
        id: Data([0xE1]),
        kind: .message,
        payload: CanonicalEncoderV1.encode(urgentMessage),
        enqueuedAt: now,
        expiresAt: now.addingTimeInterval(15)
    ))

    let plan = try router.planNextEncounter(
        context: EncounterSchedulingContext(
            budget: EncounterBudgetProfile(maxBytes: 16_000, maxItems: 10, estimatedDurationSeconds: 8),
            selectedBearer: "sim-link",
            remoteWayfarerId: peerId,
            shadowMode: .compareLegacyFallbackV1,
            shadowTopN: 3
        ),
        now: now
    )

    let comparison = try #require(plan.shadowComparison)
    #expect(comparison.topN == 3)
    #expect(!comparison.legacyTopNItemIDsHex.isEmpty)
    #expect(comparison.canonicalStopReason == canonicalStopReason(from: plan.decisionLogs))
    #expect(comparison.canonicalStopReason != nil)
}

@Test
func shadowModeComparisonDifferenceFlagsReflectComparedTelemetryFields() throws {
    let store = try makeStore()
    let router = Router(store: store)
    let now = Date(timeIntervalSince1970: 110_000)
    let peerId = Data(repeating: 0xB9, count: 32)

    let oversizedEnvelope = EnvelopeV1(
        toWayfarerId: peerId,
        manifestId: Data(repeating: 0x91, count: 32),
        body: Data(repeating: 0x41, count: 2_500)
    )
    try store.enqueue(item: OutboxItem(
        id: Data([0xF0]),
        kind: .envelope,
        payload: CanonicalEncoderV1.encode(oversizedEnvelope),
        enqueuedAt: now
    ))

    let smallMessage = MessageV1(
        createdAtUnixMs: Int64(now.timeIntervalSince1970 * 1000),
        authorWayfarerId: peerId,
        body: Data(repeating: 0x42, count: 64)
    )
    try store.enqueue(item: OutboxItem(
        id: Data([0xF1]),
        kind: .message,
        payload: CanonicalEncoderV1.encode(smallMessage),
        enqueuedAt: now
    ))

    let plan = try router.planNextEncounter(
        context: EncounterSchedulingContext(
            budget: EncounterBudgetProfile(maxBytes: 600, maxItems: 5, estimatedDurationSeconds: 30),
            selectedBearer: "sim-link",
            remoteWayfarerId: peerId,
            shadowMode: .compareLegacyFallbackV1,
            shadowTopN: 2
        ),
        now: now
    )

    let comparison = try #require(plan.shadowComparison)
    #expect(comparison.differences.contains(EncounterShadowComparison.Difference.topNChanged) == (comparison.legacyTopNItemIDsHex != comparison.canonicalTopNItemIDsHex))
    #expect(comparison.differences.contains(EncounterShadowComparison.Difference.firstSelectedChanged) == (comparison.legacyFirstSelectedItemIDHex != comparison.canonicalFirstSelectedItemIDHex))

    let canonicalStopReason = try #require(comparison.canonicalStopReason)
    #expect(comparison.differences.contains(EncounterShadowComparison.Difference.stopReasonChanged) == (comparison.legacyStopReason != canonicalStopReason))

    let canonicalTierDistribution = try #require(comparison.canonicalTierDistribution)
    #expect(comparison.differences.contains(EncounterShadowComparison.Difference.tierDistributionChanged) == (comparison.legacyTierDistribution != canonicalTierDistribution))

    let canonicalTransitDirectBalance = try #require(comparison.canonicalTransitDirectBalance)
    #expect(comparison.differences.contains(EncounterShadowComparison.Difference.transitDirectBalanceChanged) == (comparison.legacyTransitDirectBalance != canonicalTransitDirectBalance))

    let hasMappingLoss = comparison.legacyUnmappedSelectedItemCount > 0 || comparison.canonicalUnmappedSelectedItemCount > 0
    #expect(comparison.differences.contains(EncounterShadowComparison.Difference.selectedItemMappingLoss) == hasMappingLoss)
}

@Test
func shadowModeDifferenceDetectionIsDeterministicForForcedDriftInputs() {
    let differences = EncounterShadowComparison.Difference.detect(
        legacyTopNItemIDsHex: ["a"],
        canonicalTopNItemIDsHex: ["b"],
        legacyFirstSelectedItemIDHex: "a",
        canonicalFirstSelectedItemIDHex: "b",
        legacyStopReason: EncounterSelectionStopReason.completed.rawValue,
        canonicalStopReason: EncounterSelectionStopReason.budgetItemsExhausted.rawValue,
        legacyTierDistribution: [1, 0, 0, 0, 0, 0],
        canonicalTierDistribution: [0, 1, 0, 0, 0, 0],
        legacyTransitDirectBalance: EncounterShadowTransitDirectBalance(directCount: 1, transitCount: 0),
        canonicalTransitDirectBalance: EncounterShadowTransitDirectBalance(directCount: 0, transitCount: 1),
        legacyUnmappedSelectedItemCount: 1,
        canonicalUnmappedSelectedItemCount: 0
    )

    #expect(differences == [
        .topNChanged,
        .firstSelectedChanged,
        .stopReasonChanged,
        .tierDistributionChanged,
        .transitDirectBalanceChanged,
        .selectedItemMappingLoss,
    ])
}

@Test
func shadowModeDisabledPreservesCanonicalOutputsWithoutTelemetry() throws {
    let store = try makeStore()
    let router = Router(store: store)
    let now = Date(timeIntervalSince1970: 120_000)
    let peerId = Data(repeating: 0xC9, count: 32)

    let receipt = ReceiptV1(
        envelopeId: Data(repeating: 0x71, count: 32),
        manifestId: Data(repeating: 0x72, count: 32),
        receivedAtUnixMs: 1,
        signature: Data()
    )
    try store.enqueue(item: OutboxItem(id: Data([0xD0]), kind: .receipt, payload: CanonicalEncoderV1.encode(receipt), enqueuedAt: now))
    try seedChunkTransfer(store: store, now: now, toWayfarerId: peerId, idSeed: 0xD1)

    let compareContext = EncounterSchedulingContext(
        budget: EncounterBudgetProfile(maxBytes: 20_000, maxItems: 20, estimatedDurationSeconds: 45),
        selectedBearer: "sim-link",
        remoteWayfarerId: peerId,
        shadowMode: .compareLegacyFallbackV1
    )
    let disabledContext = EncounterSchedulingContext(
        budget: compareContext.budget,
        selectedBearer: compareContext.selectedBearer,
        remoteWayfarerId: compareContext.remoteWayfarerId,
        userIntentBoostItemIDs: compareContext.userIntentBoostItemIDs,
        relayIngestSafetyAvailable: compareContext.relayIngestSafetyAvailable,
        shadowMode: .disabled
    )

    let compared = try router.planNextEncounter(context: compareContext, now: now)
    let disabled = try router.planNextEncounter(context: disabledContext, now: now)

    #expect(compared.items == disabled.items)
    #expect(compared.decisionLogs == disabled.decisionLogs)
    #expect(compared.shadowComparison != nil)
    #expect(disabled.shadowComparison == nil)
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
    let fixtureURL: URL
    if let bundledURL = Bundle.module.url(
        forResource: name,
        withExtension: "json",
        subdirectory: "Fixtures/encounter-budgeting"
    ) {
        fixtureURL = bundledURL
    } else {
        fixtureURL = try repoRoot(near: #filePath)
            .appendingPathComponent("Tests/AethosCoreTests/Resources/Fixtures/encounter-budgeting", isDirectory: true)
            .appendingPathComponent("\(name).json", isDirectory: false)
    }

    let bytes = try Data(contentsOf: fixtureURL)
    return try JSONDecoder().decode(EncounterBudgetFixture.self, from: bytes)
}

private enum FixtureLookupError: Swift.Error {
    case repoRootNotFound
}

private func repoRoot(near filePath: String) throws -> URL {
    let startingDirectory = URL(fileURLWithPath: filePath).deletingLastPathComponent().standardizedFileURL
    let fileManager = FileManager.default
    var candidate = startingDirectory

    while true {
        let packageSwift = candidate.appendingPathComponent("Package.swift", isDirectory: false)
        var packageIsDir = ObjCBool(false)
        let hasPackageSwift = fileManager.fileExists(atPath: packageSwift.path, isDirectory: &packageIsDir) && !packageIsDir.boolValue
        if hasPackageSwift {
            return candidate
        }

        let parent = candidate.deletingLastPathComponent().standardizedFileURL
        if parent.path == candidate.path {
            throw FixtureLookupError.repoRootNotFound
        }
        candidate = parent
    }
}

private func canonicalStopReason(from decisionLogs: [EncounterDecisionLog]) -> String {
    let stopReason = decisionLogs.compactMap(\.stopReason).last ?? .completedCandidates
    switch stopReason {
    case .completedCandidates:
        return EncounterSelectionStopReason.completed.rawValue
    case .maxItemsReached:
        return EncounterSelectionStopReason.budgetItemsExhausted.rawValue
    case .maxBytesReached:
        return EncounterSelectionStopReason.budgetBytesExhausted.rawValue
    case .estimatedTimeBudgetReached:
        return EncounterSelectionStopReason.encounterTimeExhausted.rawValue
    case .durableCargoCapReached:
        return EncounterSelectionStopReason.durableRatioCapReached.rawValue
    }
}
