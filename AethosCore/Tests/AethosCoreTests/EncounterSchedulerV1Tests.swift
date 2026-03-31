import Foundation
import Testing
@testable import AethosCore

@Test
func encounterSchedulerMatchesCanonicalRoutingFixtures() throws {
    let scheduler = EncounterSchedulerV1()
    let manifest = try loadEncounterFixtureManifest()

    for fixturePath in manifest.fixtures.map(\.fixture) {
        let fixture = try loadEncounterFixture(path: fixturePath)
        let result = try scheduler.schedule(
            encounterClass: try fixture.encounterClassValue,
            budget: fixture.budgetProfile.schedulerBudget,
            nowUnixMs: fixture.nowUnixMs,
            cargoItems: fixture.cargoItems.map(\.schedulerItem)
        )

        #expect(result.rankingOrder == fixture.expected.rankingOrder)
        #expect(result.selectedPrefixItemIDs == fixture.expected.selectedPrefix)
        #expect(result.stopReason.rawValue == fixture.expected.stopReason)
        #expect(result.tieBreakReason.rawValue == (fixture.expected.tieBreakReason ?? EncounterTieBreakReason.none.rawValue))

        #expect(result.scoreBreakdowns.count == fixture.expected.scoreBreakdowns.count)

        for (actual, expected) in zip(result.scoreBreakdowns, fixture.expected.scoreBreakdowns) {
            #expect(actual.itemID == expected.itemID)
            #expect(actual.scoreNumerator == expected.scoreNumerator)
            #expect(millionths(actual.components.scarcity) == millionths(expected.components.scarcity))
            #expect(millionths(actual.components.safety) == millionths(expected.components.safety))
            #expect(millionths(actual.components.expiry) == millionths(expected.components.expiry))
            #expect(millionths(actual.components.stagnation) == millionths(expected.components.stagnation))
            #expect(millionths(actual.components.proximity) == millionths(expected.components.proximity))
            #expect(millionths(actual.components.size) == millionths(expected.components.size))
            #expect(millionths(actual.components.intent) == millionths(expected.components.intent))
            #expect(millionths(actual.components.contentClass) == millionths(expected.components.contentClass))
            #expect(scoreDenominator(actual.score) == scoreDenominator(expected.score))
        }
    }
}

@Test
func encounterSchedulerScoreMathMatchesCanonicalKnownVector() throws {
    let scheduler = EncounterSchedulerV1()
    let nowUnixMs: UInt64 = 1_760_000_000_000
    let item = EncounterSchedulerV1.CargoItem(
        itemID: "0000000000000000000000000000000000000000000000000000000000000101",
        tier: 0,
        sizeBytes: 256,
        expiryAtUnixMs: 1_760_000_120_000,
        knownReplicaCount: 0,
        receiptCoverage: 0.1,
        lastForwardedAtUnixMs: 1_759_999_400_000,
        proximityClass: .destinationPeer,
        explicitUserInitiated: true,
        contentClassScore: 0.3,
        destinationRank: 9
    )

    let result = try scheduler.schedule(
        encounterClass: .blink,
        budget: .init(maxItems: 1, maxBytes: 10_000_000),
        nowUnixMs: nowUnixMs,
        cargoItems: [item]
    )
    let breakdown = try #require(result.scoreBreakdowns.first)

    #expect(millionths(breakdown.components.scarcity) == 1_000_000)
    #expect(millionths(breakdown.components.safety) == 980_000)
    #expect(millionths(breakdown.components.expiry) == 866_667)
    #expect(millionths(breakdown.components.stagnation) == 166_667)
    #expect(millionths(breakdown.components.proximity) == 1_000_000)
    #expect(millionths(breakdown.components.size) == 466_293)
    #expect(millionths(breakdown.components.intent) == 1_000_000)
    #expect(millionths(breakdown.components.contentClass) == 300_000)
    #expect(breakdown.scoreNumerator == 81_757_020)
    #expect(scoreDenominator(breakdown.score) == 81_757_020)
}

@Test
func encounterSchedulerTieBreakChainIsDeterministicAndOrdered() throws {
    let scheduler = EncounterSchedulerV1()
    let nowUnixMs: UInt64 = 1_760_000_000_000
    let commonExpiry: UInt64 = 1_760_008_000_000

    func makeItem(
        id: String,
        sizeBytes: Int,
        expiryAtUnixMs: UInt64,
        knownReplicaCount: Int,
        lastForwardedAtUnixMs: UInt64,
        destinationRank: Int
    ) -> EncounterSchedulerV1.CargoItem {
        .init(
            itemID: id,
            tier: 4,
            sizeBytes: sizeBytes,
            expiryAtUnixMs: expiryAtUnixMs,
            knownReplicaCount: knownReplicaCount,
            targetReplicaCount: 6,
            receiptCoverage: 0.5,
            lastForwardedAtUnixMs: lastForwardedAtUnixMs,
            proximityClass: .likelyCloser,
            contentClassScore: 0.5,
            destinationRank: destinationRank
        )
    }

    let itemSizeSmall = makeItem(
        id: "1111111111111111111111111111111111111111111111111111111111111111",
        sizeBytes: 40_000,
        expiryAtUnixMs: commonExpiry,
        knownReplicaCount: 6,
        lastForwardedAtUnixMs: 1_759_990_000_000,
        destinationRank: 7
    )
    let itemSizeLarge = makeItem(
        id: "1111111111111111111111111111111111111111111111111111111111111112",
        sizeBytes: 60_000,
        expiryAtUnixMs: commonExpiry,
        knownReplicaCount: 6,
        lastForwardedAtUnixMs: 1_759_990_000_000,
        destinationRank: 7
    )

    let itemExpiryEarly = makeItem(
        id: "2222222222222222222222222222222222222222222222222222222222222222",
        sizeBytes: 40_000,
        expiryAtUnixMs: 1_760_008_000_000,
        knownReplicaCount: 6,
        lastForwardedAtUnixMs: 1_759_990_000_000,
        destinationRank: 7
    )
    let itemExpiryLate = makeItem(
        id: "2222222222222222222222222222222222222222222222222222222222222223",
        sizeBytes: 40_000,
        expiryAtUnixMs: 1_760_009_000_000,
        knownReplicaCount: 6,
        lastForwardedAtUnixMs: 1_759_990_000_000,
        destinationRank: 7
    )

    let itemReplicaLow = makeItem(
        id: "3333333333333333333333333333333333333333333333333333333333333333",
        sizeBytes: 40_000,
        expiryAtUnixMs: commonExpiry,
        knownReplicaCount: 6,
        lastForwardedAtUnixMs: 1_759_990_000_000,
        destinationRank: 7
    )
    let itemReplicaHigh = makeItem(
        id: "3333333333333333333333333333333333333333333333333333333333333334",
        sizeBytes: 40_000,
        expiryAtUnixMs: commonExpiry,
        knownReplicaCount: 9,
        lastForwardedAtUnixMs: 1_759_990_000_000,
        destinationRank: 7
    )

    let itemForwardOlder = makeItem(
        id: "4444444444444444444444444444444444444444444444444444444444444444",
        sizeBytes: 40_000,
        expiryAtUnixMs: commonExpiry,
        knownReplicaCount: 6,
        lastForwardedAtUnixMs: 1_759_900_000_000,
        destinationRank: 7
    )
    let itemForwardNewer = makeItem(
        id: "4444444444444444444444444444444444444444444444444444444444444445",
        sizeBytes: 40_000,
        expiryAtUnixMs: commonExpiry,
        knownReplicaCount: 6,
        lastForwardedAtUnixMs: 1_759_950_000_000,
        destinationRank: 7
    )

    let itemDestinationHigh = makeItem(
        id: "5555555555555555555555555555555555555555555555555555555555555555",
        sizeBytes: 40_000,
        expiryAtUnixMs: commonExpiry,
        knownReplicaCount: 6,
        lastForwardedAtUnixMs: 1_759_990_000_000,
        destinationRank: 9
    )
    let itemDestinationLow = makeItem(
        id: "5555555555555555555555555555555555555555555555555555555555555556",
        sizeBytes: 40_000,
        expiryAtUnixMs: commonExpiry,
        knownReplicaCount: 6,
        lastForwardedAtUnixMs: 1_759_990_000_000,
        destinationRank: 5
    )

    let itemIDHigh = makeItem(
        id: "fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff1",
        sizeBytes: 40_000,
        expiryAtUnixMs: commonExpiry,
        knownReplicaCount: 6,
        lastForwardedAtUnixMs: 1_759_990_000_000,
        destinationRank: 7
    )
    let itemIDLow = makeItem(
        id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1",
        sizeBytes: 40_000,
        expiryAtUnixMs: commonExpiry,
        knownReplicaCount: 6,
        lastForwardedAtUnixMs: 1_759_990_000_000,
        destinationRank: 7
    )

    let items = [
        itemSizeLarge,
        itemSizeSmall,
        itemExpiryLate,
        itemExpiryEarly,
        itemReplicaHigh,
        itemReplicaLow,
        itemForwardNewer,
        itemForwardOlder,
        itemDestinationLow,
        itemDestinationHigh,
        itemIDLow,
        itemIDHigh,
    ]

    let result = try scheduler.schedule(
        encounterClass: .short,
        budget: .init(maxItems: 12, maxBytes: 2_000_000),
        nowUnixMs: nowUnixMs,
        cargoItems: items
    )

    let ranking = result.rankingOrder
    #expect(firstIndex(of: itemSizeSmall.itemID, in: ranking) < firstIndex(of: itemSizeLarge.itemID, in: ranking))
    #expect(firstIndex(of: itemExpiryEarly.itemID, in: ranking) < firstIndex(of: itemExpiryLate.itemID, in: ranking))
    #expect(firstIndex(of: itemReplicaLow.itemID, in: ranking) < firstIndex(of: itemReplicaHigh.itemID, in: ranking))
    #expect(firstIndex(of: itemForwardOlder.itemID, in: ranking) < firstIndex(of: itemForwardNewer.itemID, in: ranking))
    #expect(firstIndex(of: itemDestinationHigh.itemID, in: ranking) < firstIndex(of: itemDestinationLow.itemID, in: ranking))
    #expect(firstIndex(of: itemIDHigh.itemID, in: ranking) < firstIndex(of: itemIDLow.itemID, in: ranking))
}

@Test
func encounterSchedulerIsStableAcrossRepeatedRuns() throws {
    let scheduler = EncounterSchedulerV1()
    let fixture = try loadEncounterFixture(path: "./repeated-run-stability-mixed-ties.json")
    let baseline = try scheduler.schedule(
        encounterClass: try fixture.encounterClassValue,
        budget: fixture.budgetProfile.schedulerBudget,
        nowUnixMs: fixture.nowUnixMs,
        cargoItems: fixture.cargoItems.map(\.schedulerItem)
    )

    for _ in 0..<64 {
        let rerun = try scheduler.schedule(
            encounterClass: try fixture.encounterClassValue,
            budget: fixture.budgetProfile.schedulerBudget,
            nowUnixMs: fixture.nowUnixMs,
            cargoItems: fixture.cargoItems.map(\.schedulerItem)
        )
        #expect(rerun == baseline)
    }
}

@Test
func encounterSchedulerHandlesHorizonAndExpiryEdgeCases() throws {
    let scheduler = EncounterSchedulerV1()
    let nowUnixMs: UInt64 = 1_760_000_000_000

    let filteredByClockSkew = EncounterSchedulerV1.CargoItem(
        itemID: "0000000000000000000000000000000000000000000000000000000000000901",
        tier: 1,
        sizeBytes: 100,
        expiryAtUnixMs: nowUnixMs + 30_000,
        destinationRank: 1
    )

    let atExpiryHorizon = EncounterSchedulerV1.CargoItem(
        itemID: "0000000000000000000000000000000000000000000000000000000000000902",
        tier: 1,
        sizeBytes: 100,
        expiryAtUnixMs: nowUnixMs + 900_000,
        lastForwardedAtUnixMs: nowUnixMs - 3_600_000,
        destinationRank: 2
    )

    let result = try scheduler.schedule(
        encounterClass: .short,
        budget: .init(maxItems: 10, maxBytes: 100_000),
        nowUnixMs: nowUnixMs,
        cargoItems: [filteredByClockSkew, atExpiryHorizon]
    )

    #expect(result.rankingOrder == [atExpiryHorizon.itemID])
    let scored = try #require(result.scoreBreakdowns.first)
    #expect(millionths(scored.components.expiry) == 0)
    #expect(millionths(scored.components.stagnation) == 1_000_000)
}

@Test
func encounterSchedulerLogarithmicSizeCurveIsMonotonicAndSaturates() throws {
    let scheduler = EncounterSchedulerV1()
    let nowUnixMs: UInt64 = 1_760_000_000_000

    let tiny = EncounterSchedulerV1.CargoItem(
        itemID: "0000000000000000000000000000000000000000000000000000000000000a01",
        tier: 3,
        sizeBytes: 1,
        expiryAtUnixMs: nowUnixMs + 1_800_000,
        destinationRank: 1
    )
    let medium = EncounterSchedulerV1.CargoItem(
        itemID: "0000000000000000000000000000000000000000000000000000000000000a02",
        tier: 3,
        sizeBytes: 1_024,
        expiryAtUnixMs: nowUnixMs + 1_800_000,
        destinationRank: 1
    )
    let preferredUnit = EncounterSchedulerV1.CargoItem(
        itemID: "0000000000000000000000000000000000000000000000000000000000000a03",
        tier: 3,
        sizeBytes: 32_768,
        expiryAtUnixMs: nowUnixMs + 1_800_000,
        destinationRank: 1
    )
    let beyondPreferredUnit = EncounterSchedulerV1.CargoItem(
        itemID: "0000000000000000000000000000000000000000000000000000000000000a04",
        tier: 3,
        sizeBytes: 65_536,
        expiryAtUnixMs: nowUnixMs + 1_800_000,
        destinationRank: 1
    )

    let result = try scheduler.schedule(
        encounterClass: .durable,
        budget: .init(maxItems: 10, maxBytes: 1_000_000),
        nowUnixMs: nowUnixMs,
        cargoItems: [tiny, medium, preferredUnit, beyondPreferredUnit]
    )

    let byID = Dictionary(uniqueKeysWithValues: result.scoreBreakdowns.map { ($0.itemID, $0.components.size) })
    let tinySize = try #require(byID[tiny.itemID])
    let mediumSize = try #require(byID[medium.itemID])
    let preferredSize = try #require(byID[preferredUnit.itemID])
    let beyondPreferredSize = try #require(byID[beyondPreferredUnit.itemID])

    #expect(tinySize > mediumSize)
    #expect(mediumSize > preferredSize)
    #expect(millionths(preferredSize) == 0)
    #expect(millionths(beyondPreferredSize) == 0)
}

private struct EncounterFixtureManifest: Decodable {
    struct FixtureReference: Decodable {
        let fixture: String
    }

    let fixtures: [FixtureReference]
}

private struct EncounterFixture: Decodable {
    struct BudgetProfile: Decodable {
        let maxItems: Int
        let maxBytes: Int
        let maxDurationMs: Int?
        let durableCargoRatioCap: Double?
        let preferredTransferUnitBytes: Int?
        let expiryUrgencyHorizonMs: UInt64?
        let stagnationHorizonMs: UInt64?
        let targetReplicaCountDefault: Int?

        var schedulerBudget: EncounterSchedulerV1.BudgetProfile {
            EncounterSchedulerV1.BudgetProfile(
                maxItems: maxItems,
                maxBytes: maxBytes,
                maxDurationMs: maxDurationMs,
                durableCargoRatioCap: durableCargoRatioCap,
                preferredTransferUnitBytes: preferredTransferUnitBytes ?? 32_768,
                expiryUrgencyHorizonMs: expiryUrgencyHorizonMs ?? 900_000,
                stagnationHorizonMs: stagnationHorizonMs ?? 3_600_000,
                targetReplicaCountDefault: targetReplicaCountDefault ?? 6
            )
        }
    }

    struct CargoItem: Decodable {
        let itemID: String
        let tier: Int
        let sizeBytes: Int
        let expiryAtUnixMs: UInt64
        let knownReplicaCount: Int?
        let targetReplicaCount: Int?
        let durablyStored: Bool?
        let relayIngested: Bool?
        let receiptCoverage: Double?
        let lastForwardedAtUnixMs: UInt64?
        let proximityClass: EncounterSchedulerV1.ProximityClass?
        let explicitUserInitiated: Bool?
        let contentClassScore: Double?
        let destinationRank: Int
        let estimatedDurationMs: Int?

        var schedulerItem: EncounterSchedulerV1.CargoItem {
            EncounterSchedulerV1.CargoItem(
                itemID: itemID,
                tier: tier,
                sizeBytes: sizeBytes,
                expiryAtUnixMs: expiryAtUnixMs,
                knownReplicaCount: knownReplicaCount,
                targetReplicaCount: targetReplicaCount,
                durablyStored: durablyStored,
                relayIngested: relayIngested,
                receiptCoverage: receiptCoverage,
                lastForwardedAtUnixMs: lastForwardedAtUnixMs,
                proximityClass: proximityClass,
                explicitUserInitiated: explicitUserInitiated,
                contentClassScore: contentClassScore,
                destinationRank: destinationRank,
                estimatedDurationMs: estimatedDurationMs
            )
        }
    }

    struct Expected: Decodable {
        struct ScoreBreakdown: Decodable {
            struct Components: Decodable {
                let scarcity: Double
                let safety: Double
                let expiry: Double
                let stagnation: Double
                let proximity: Double
                let size: Double
                let intent: Double
                let contentClass: Double
            }

            let itemID: String
            let components: Components
            let scoreNumerator: Int
            let score: Double
        }

        let rankingOrder: [String]
        let selectedPrefix: [String]
        let scoreBreakdowns: [ScoreBreakdown]
        let stopReason: String
        let tieBreakReason: String?
    }

    let encounterClass: String
    let nowUnixMs: UInt64
    let budgetProfile: BudgetProfile
    let cargoItems: [CargoItem]
    let expected: Expected

    var encounterClassValue: EncounterClass {
        get throws {
            guard let value = EncounterClass(rawValue: encounterClass) else {
                throw FixtureError.invalidEncounterClass(encounterClass)
            }
            return value
        }
    }
}

private enum FixtureError: Swift.Error {
    case invalidEncounterClass(String)
    case repoRootNotFound
}

private func loadEncounterFixtureManifest() throws -> EncounterFixtureManifest {
    let data = try Data(contentsOf: encounterFixtureRoot().appendingPathComponent("manifest.json", isDirectory: false))
    return try JSONDecoder().decode(EncounterFixtureManifest.self, from: data)
}

private func loadEncounterFixture(path fixturePath: String) throws -> EncounterFixture {
    let normalizedPath: String
    if fixturePath.hasPrefix("./") {
        normalizedPath = String(fixturePath.dropFirst(2))
    } else {
        normalizedPath = fixturePath
    }
    let data = try Data(contentsOf: encounterFixtureRoot().appendingPathComponent(normalizedPath, isDirectory: false))
    return try JSONDecoder().decode(EncounterFixture.self, from: data)
}

private func encounterFixtureRoot(filePath: String = #filePath) throws -> URL {
    try repoRoot(near: filePath).appendingPathComponent("Fixtures/Routing/encounter-ranking", isDirectory: true)
}

private func repoRoot(near filePath: String) throws -> URL {
    let startingDirectory = URL(fileURLWithPath: filePath).deletingLastPathComponent().standardizedFileURL
    let fileManager = FileManager.default
    var candidate = startingDirectory

    while true {
        let packageSwift = candidate.appendingPathComponent("Package.swift", isDirectory: false)
        let fixturesDir = candidate.appendingPathComponent("Fixtures/Routing/encounter-ranking", isDirectory: true)

        var packageIsDir = ObjCBool(false)
        let hasPackageSwift = fileManager.fileExists(atPath: packageSwift.path, isDirectory: &packageIsDir) && !packageIsDir.boolValue

        var fixturesIsDir = ObjCBool(false)
        let hasFixturesDir = fileManager.fileExists(atPath: fixturesDir.path, isDirectory: &fixturesIsDir) && fixturesIsDir.boolValue

        if hasPackageSwift && hasFixturesDir {
            return candidate
        }

        let parent = candidate.deletingLastPathComponent().standardizedFileURL
        if parent.path == candidate.path {
            throw FixtureError.repoRootNotFound
        }
        candidate = parent
    }
}

private func millionths(_ value: Double) -> Int {
    Int((value * 1_000_000).rounded(.toNearestOrEven))
}

private func scoreDenominator(_ value: Double) -> Int {
    Int((value * 100_000_000).rounded(.toNearestOrEven))
}

private func firstIndex(of itemID: String, in array: [String]) -> Int {
    array.firstIndex(of: itemID) ?? Int.max
}
