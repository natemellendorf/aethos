import Foundation
import XCTest
@testable import AethosCore

final class MixedBearerFixtureRunnerTests: XCTestCase {
    func testMixedBearerManifestSchemaVersionAndLaneContract() throws {
        let manifest = try MixedBearerFixtureTestSupport.loadManifest()

        XCTAssertEqual(
            manifest.schemaVersion,
            "mbe-mixed-bearer.v1",
            "Mixed-bearer manifest schemaVersion drifted; runner expects mbe-mixed-bearer.v1"
        )

        XCTAssertEqual(
            Set(manifest.lanes),
            Set(MixedBearerFixtureTestSupport.telemetryLaneKeys),
            "Manifest lanes must exactly include encounter, forwarding, admin_record"
        )

        XCTAssertFalse(manifest.fixtures.isEmpty, "Manifest must list at least one fixture")
    }

    func testMixedBearerFixturesMeetDeterministicRunnerInvariants() throws {
        let manifest = try MixedBearerFixtureTestSupport.loadManifest()
        let fixturePaths = manifest.fixtures.map(\.normalizedFixtureRelativePath)

        let uniqueFixturePaths = Set(fixturePaths)
        XCTAssertEqual(uniqueFixturePaths.count, fixturePaths.count, "Manifest fixture list contains duplicate paths")

        for fixtureReference in manifest.fixtures {
            let relativePath = fixtureReference.normalizedFixtureRelativePath
            try validateFixture(relativePath: relativePath, fixtureReference: fixtureReference, manifest: manifest)
        }
    }
}

private extension MixedBearerFixtureRunnerTests {
    func validateFixture(
        relativePath: String,
        fixtureReference: MixedBearerFixtureTestSupport.FixtureReference,
        manifest: MixedBearerFixtureTestSupport.Manifest
    ) throws {
        guard MixedBearerFixtureTestSupport.telemetryLaneKeys.contains(fixtureReference.lane) else {
            throw MixedBearerFixtureRunnerError.invalidFixture(
                relativePath: relativePath,
                detail: "Manifest lane \(fixtureReference.lane) is not one of \(MixedBearerFixtureTestSupport.telemetryLaneKeys)"
            )
        }

        let fixtureJSON = try MixedBearerFixtureTestSupport.loadFixtureJSON(relativePath: relativePath)
        try assertTelemetryLayerKeysExist(in: fixtureJSON, relativePath: relativePath)

        let fixture = try MixedBearerFixtureTestSupport.loadFixture(relativePath: relativePath)
        try assertSchemaVersionMatchesManifest(fixture: fixture, manifest: manifest, relativePath: relativePath)
        try assertTimeScopeInvariants(fixture: fixture, relativePath: relativePath)
        try assertExpectedOutcomeRefusalCoherence(fixture: fixture, manifest: manifest, relativePath: relativePath)

        let telemetryEvents = try decodeAndValidateTelemetryEvents(
            fixtureJSON: fixtureJSON,
            fixture: fixture,
            manifest: manifest,
            relativePath: relativePath
        )
        try assertEventSequenceMonotonicByEncounterAttempt(events: telemetryEvents, relativePath: relativePath)
    }

    func assertSchemaVersionMatchesManifest(
        fixture: MixedBearerFixtureTestSupport.FixtureDocument,
        manifest: MixedBearerFixtureTestSupport.Manifest,
        relativePath: String
    ) throws {
        guard fixture.schemaVersion == manifest.schemaVersion else {
            throw MixedBearerFixtureRunnerError.invalidFixture(
                relativePath: relativePath,
                detail: "Fixture schemaVersion \(fixture.schemaVersion) does not match manifest schemaVersion \(manifest.schemaVersion)"
            )
        }
    }

    func assertTelemetryLayerKeysExist(in fixtureJSON: [String: Any], relativePath: String) throws {
        for laneKey in MixedBearerFixtureTestSupport.telemetryLaneKeys {
            guard let laneAny = fixtureJSON[laneKey] else {
                throw MixedBearerFixtureRunnerError.invalidFixture(
                    relativePath: relativePath,
                    detail: "Missing required telemetry layer key: \(laneKey)"
                )
            }
            guard laneAny is [Any] else {
                throw MixedBearerFixtureRunnerError.invalidFixture(
                    relativePath: relativePath,
                    detail: "Telemetry layer \(laneKey) must be an array (can be empty)"
                )
            }
        }
    }

    func decodeAndValidateTelemetryEvents(
        fixtureJSON: [String: Any],
        fixture: MixedBearerFixtureTestSupport.FixtureDocument,
        manifest: MixedBearerFixtureTestSupport.Manifest,
        relativePath: String
    ) throws -> [TelemetryEvent] {
        var combinedEvents: [TelemetryEvent] = []

        for laneKey in MixedBearerFixtureTestSupport.telemetryLaneKeys {
            guard let laneEventsAny = fixtureJSON[laneKey] as? [Any] else {
                throw MixedBearerFixtureRunnerError.invalidFixture(
                    relativePath: relativePath,
                    detail: "Telemetry lane \(laneKey) was not an array during event decoding"
                )
            }

            for (index, eventAny) in laneEventsAny.enumerated() {
                guard let eventObject = eventAny as? [String: Any] else {
                    throw MixedBearerFixtureRunnerError.invalidFixture(
                        relativePath: relativePath,
                        detail: "\(laneKey)[\(index)] must be a JSON object"
                    )
                }

                try assertRequiredEnvelopeKeysExist(
                    eventObject,
                    relativePath: relativePath,
                    laneKey: laneKey,
                    index: index
                )

                let event = try MixedBearerFixtureTestSupport.decodeTelemetryEvent(
                    rawObject: eventObject,
                    relativePath: relativePath,
                    laneKey: laneKey,
                    index: index
                )

                guard event.contractVersion == 1 else {
                    throw MixedBearerFixtureRunnerError.invalidFixture(
                        relativePath: relativePath,
                        detail: "\(laneKey)[\(index)] contractVersion must be 1"
                    )
                }

                guard event.layer.rawValue == laneKey else {
                    throw MixedBearerFixtureRunnerError.invalidFixture(
                        relativePath: relativePath,
                        detail: "\(laneKey)[\(index)] layer mismatch: expected \(laneKey), got \(event.layer.rawValue)"
                    )
                }

                if case let .string(refusalCode)? = event.payload["refusalReason"] {
                    try assertRefusalReasonCodeDeclaredIfNeeded(
                        refusalCode,
                        fixture: fixture,
                        manifest: manifest,
                        relativePath: relativePath,
                        context: "\(laneKey)[\(index)].payload.refusalReason"
                    )
                }

                combinedEvents.append(event)
            }
        }

        return combinedEvents
    }

    func assertRequiredEnvelopeKeysExist(
        _ eventObject: [String: Any],
        relativePath: String,
        laneKey: String,
        index: Int
    ) throws {
        let context = "\(relativePath):\(laneKey)[\(index)]"

        let alwaysRequired: [String] = [
            "contractVersion",
            "eventID",
            "encounterAttemptID",
            "eventSequence",
            "layer",
            "payload",
        ]

        for key in alwaysRequired where eventObject[key] == nil {
            throw MixedBearerFixtureRunnerError.invalidFixture(
                relativePath: relativePath,
                detail: "\(context) missing required envelope key \(key)"
            )
        }

        try assertAliasKeyExists(
            eventObject,
            aliases: ["eventType", "kind"],
            expectedKeyName: "kind",
            relativePath: relativePath,
            context: context
        )

        try assertAliasKeyExists(
            eventObject,
            aliases: ["occurredAtUnixMs", "createdAtUnixMs"],
            expectedKeyName: "createdAtUnixMs",
            relativePath: relativePath,
            context: context
        )

        try assertAliasKeyExists(
            eventObject,
            aliases: ["encounterContextID", "encounterID"],
            expectedKeyName: "encounterID",
            relativePath: relativePath,
            context: context
        )
    }

    func assertAliasKeyExists(
        _ eventObject: [String: Any],
        aliases: [String],
        expectedKeyName: String,
        relativePath: String,
        context: String
    ) throws {
        guard aliases.contains(where: { eventObject[$0] != nil }) else {
            throw MixedBearerFixtureRunnerError.invalidFixture(
                relativePath: relativePath,
                detail: "\(context) missing required envelope key \(expectedKeyName) (accepted aliases: \(aliases.joined(separator: ", ")))"
            )
        }
    }

    func assertEventSequenceMonotonicByEncounterAttempt(events: [TelemetryEvent], relativePath: String) throws {
        let groupedByAttempt = Dictionary(grouping: events, by: { $0.encounterAttemptID.rawValue })

        for (encounterAttemptID, attemptEvents) in groupedByAttempt {
            let sortedSequences = attemptEvents.map(\.eventSequence).sorted()
            guard Set(sortedSequences).count == sortedSequences.count else {
                throw MixedBearerFixtureRunnerError.invalidFixture(
                    relativePath: relativePath,
                    detail: "eventSequence contains duplicates for encounterAttemptID \(encounterAttemptID): \(sortedSequences)"
                )
            }

            for index in 1..<sortedSequences.count {
                guard sortedSequences[index] > sortedSequences[index - 1] else {
                    throw MixedBearerFixtureRunnerError.invalidFixture(
                        relativePath: relativePath,
                        detail: "eventSequence must be strictly increasing for encounterAttemptID \(encounterAttemptID); got \(sortedSequences)"
                    )
                }
            }
        }
    }

    func assertExpectedOutcomeRefusalCoherence(
        fixture: MixedBearerFixtureTestSupport.FixtureDocument,
        manifest: MixedBearerFixtureTestSupport.Manifest,
        relativePath: String
    ) throws {
        switch fixture.expected.outcome {
        case .accept:
            guard fixture.expected.refusalReason == nil else {
                throw MixedBearerFixtureRunnerError.invalidFixture(
                    relativePath: relativePath,
                    detail: "expected.outcome=accept MUST NOT include expected.refusalReason"
                )
            }

        case .reject, .stop, .deferred:
            guard let refusalReason = fixture.expected.refusalReason else {
                throw MixedBearerFixtureRunnerError.invalidFixture(
                    relativePath: relativePath,
                    detail: "expected.outcome=\(fixture.expected.outcome.rawValue) MUST include expected.refusalReason"
                )
            }

            try assertRefusalReasonCodeDeclaredIfNeeded(
                refusalReason.rawValue,
                fixture: fixture,
                manifest: manifest,
                relativePath: relativePath,
                context: "expected.refusalReason"
            )
        }
    }

    func assertRefusalReasonCodeDeclaredIfNeeded(
        _ code: String,
        fixture: MixedBearerFixtureTestSupport.FixtureDocument,
        manifest: MixedBearerFixtureTestSupport.Manifest,
        relativePath: String,
        context: String
    ) throws {
        guard let parsedCode = RefusalReason(rawValue: code) else {
            throw MixedBearerFixtureRunnerError.invalidFixture(
                relativePath: relativePath,
                detail: "\(context) contains invalid refusalReason code: \(code)"
            )
        }

        guard parsedCode.isExtension else { return }

        let fixtureDeclared = Set((fixture.declaredExtensionRefusalReasons ?? []).map(\.code))
        let manifestDeclared = Set((manifest.extensions?.declaredExtensionRefusalReasons ?? []).map(\.code))
        let manifestDeclarationsEnabled = fixture.extensionRefusalReasonsDeclaredInManifest == true

        let declaredInFixture = fixtureDeclared.contains(code)
        let declaredInManifest = manifestDeclarationsEnabled && manifestDeclared.contains(code)

        guard declaredInFixture || declaredInManifest else {
            throw MixedBearerFixtureRunnerError.invalidFixture(
                relativePath: relativePath,
                detail: "\(context) uses extension refusalReason \(code) but it is not declared per suite rules (fixture declarations: \(fixtureDeclared.sorted()), manifest declarations available: \(manifestDeclared.sorted()), extensionRefusalReasonsDeclaredInManifest=\(manifestDeclarationsEnabled))"
            )
        }
    }

    func assertTimeScopeInvariants(
        fixture: MixedBearerFixtureTestSupport.FixtureDocument,
        relativePath: String
    ) throws {
        let observedAtLteStaleAfter = fixture.timeScope.observedAtUnixMs <= fixture.timeScope.staleAfterUnixMs
        let staleAfterLteValidUntil = fixture.timeScope.validUntilUnixMs.map { fixture.timeScope.staleAfterUnixMs <= $0 }
        let hasInvariantViolation = !observedAtLteStaleAfter || (staleAfterLteValidUntil == false)
        let expectedRefusalReason = fixture.expected.refusalReason

        if hasInvariantViolation {
            guard expectedRefusalReason == .timeScopeInvalid else {
                throw MixedBearerFixtureRunnerError.invalidFixture(
                    relativePath: relativePath,
                    detail: "timeScope invariants were violated (observedAt<=staleAfter: \(observedAtLteStaleAfter), staleAfter<=validUntil: \(String(describing: staleAfterLteValidUntil))) but expected.refusalReason was \(expectedRefusalReason?.rawValue ?? "nil") instead of time_scope_invalid"
                )
            }
            return
        }

        if expectedRefusalReason == .timeScopeInvalid {
            throw MixedBearerFixtureRunnerError.invalidFixture(
                relativePath: relativePath,
                detail: "expected.refusalReason is time_scope_invalid but top-level timeScope invariants are valid; fixture no longer encodes deterministic invalid-order evidence"
            )
        }
    }
}

private enum MixedBearerFixtureRunnerError: Swift.Error, CustomStringConvertible {
    case invalidFixture(relativePath: String, detail: String)

    var description: String {
        switch self {
        case .invalidFixture(let relativePath, let detail):
            return "Mixed-bearer fixture runner failure [\(relativePath)]: \(detail)"
        }
    }
}
