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
        let schemaRules = try MixedBearerFixtureTestSupport.loadSchemaSubsetValidationRules()
        let fixturePaths = manifest.fixtures.map(\.normalizedFixtureRelativePath)

        let uniqueFixturePaths = Set(fixturePaths)
        XCTAssertEqual(uniqueFixturePaths.count, fixturePaths.count, "Manifest fixture list contains duplicate paths")

        for fixtureReference in manifest.fixtures {
            let relativePath = fixtureReference.normalizedFixtureRelativePath
            try validateFixture(
                relativePath: relativePath,
                fixtureReference: fixtureReference,
                manifest: manifest,
                schemaRules: schemaRules
            )
        }
    }
}

private extension MixedBearerFixtureRunnerTests {
    func validateFixture(
        relativePath: String,
        fixtureReference: MixedBearerFixtureTestSupport.FixtureReference,
        manifest: MixedBearerFixtureTestSupport.Manifest,
        schemaRules: MixedBearerFixtureTestSupport.SchemaSubsetValidationRules
    ) throws {
        guard MixedBearerFixtureTestSupport.telemetryLaneKeys.contains(fixtureReference.lane) else {
            throw MixedBearerFixtureRunnerError.invalidFixture(
                relativePath: relativePath,
                detail: "Manifest lane \(fixtureReference.lane) is not one of \(MixedBearerFixtureTestSupport.telemetryLaneKeys)"
            )
        }

        let fixtureJSON = try MixedBearerFixtureTestSupport.loadFixtureJSON(relativePath: relativePath)
        try assertSchemaSubsetValidation(
            in: fixtureJSON,
            schemaRules: schemaRules,
            relativePath: relativePath
        )
        try assertTelemetryLayerKeysExist(in: fixtureJSON, relativePath: relativePath)

        let fixture = try MixedBearerFixtureTestSupport.loadFixture(relativePath: relativePath)
        try assertSchemaVersionMatchesManifest(fixture: fixture, manifest: manifest, relativePath: relativePath)
        try assertTimeScopeInvariants(fixture: fixture, relativePath: relativePath)
        try assertExpectedOutcomeRefusalCoherence(fixture: fixture, manifest: manifest, relativePath: relativePath)
        try assertExpectedTerminalOutcomeStopClassCoherence(fixture: fixture, relativePath: relativePath)

        let telemetryEvents = try decodeAndValidateTelemetryEvents(
            fixtureJSON: fixtureJSON,
            fixture: fixture,
            manifest: manifest,
            schemaRules: schemaRules,
            relativePath: relativePath
        )
        try assertEventSequenceMonotonicByEncounterAttempt(events: telemetryEvents, relativePath: relativePath)
    }

    /// Validates a schema.json-driven subset only (not full JSON Schema evaluation).
    func assertSchemaSubsetValidation(
        in fixtureJSON: [String: Any],
        schemaRules: MixedBearerFixtureTestSupport.SchemaSubsetValidationRules,
        relativePath: String
    ) throws {
        for requiredKey in schemaRules.rootRequiredKeys.sorted() where fixtureJSON[requiredKey] == nil {
            throw MixedBearerFixtureRunnerError.invalidFixture(
                relativePath: relativePath,
                detail: "schema.json subset validation: missing required top-level key \(requiredKey)"
            )
        }

        guard let expectedObject = fixtureJSON["expected"] as? [String: Any] else {
            throw MixedBearerFixtureRunnerError.invalidFixture(
                relativePath: relativePath,
                detail: "schema.json subset validation: expected must be an object"
            )
        }

        if let terminalOutcomeAny = expectedObject["terminalOutcome"] {
            guard let terminalOutcomeToken = terminalOutcomeAny as? String else {
                throw MixedBearerFixtureRunnerError.invalidFixture(
                    relativePath: relativePath,
                    detail: "schema.json subset validation: expected.terminalOutcome must be a string"
                )
            }
            guard schemaRules.terminalOutcomeTokens.contains(terminalOutcomeToken) else {
                throw MixedBearerFixtureRunnerError.invalidFixture(
                    relativePath: relativePath,
                    detail: "schema.json subset validation: expected.terminalOutcome must be one of \(schemaRules.terminalOutcomeTokens.sorted())"
                )
            }
        }

        if let stopClassAny = expectedObject["stopClass"] {
            guard let stopClassToken = stopClassAny as? String else {
                throw MixedBearerFixtureRunnerError.invalidFixture(
                    relativePath: relativePath,
                    detail: "schema.json subset validation: expected.stopClass must be a string"
                )
            }
            guard schemaRules.stopClassTokens.contains(stopClassToken) else {
                throw MixedBearerFixtureRunnerError.invalidFixture(
                    relativePath: relativePath,
                    detail: "schema.json subset validation: expected.stopClass must be one of \(schemaRules.stopClassTokens.sorted())"
                )
            }
        }
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
        schemaRules: MixedBearerFixtureTestSupport.SchemaSubsetValidationRules,
        relativePath: String
    ) throws -> [MixedBearerFixtureTestSupport.TelemetryFixtureEvent] {
        var combinedEvents: [MixedBearerFixtureTestSupport.TelemetryFixtureEvent] = []

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
                    index: index,
                    requiredKeys: schemaRules.telemetryEventRequiredKeys
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
                } else if event.payload["refusalReason"] != nil {
                    throw MixedBearerFixtureRunnerError.invalidFixture(
                        relativePath: relativePath,
                        detail: "\(laneKey)[\(index)].payload.refusalReason must be a string when present"
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
        index: Int,
        requiredKeys: Set<String>
    ) throws {
        let context = "\(relativePath):\(laneKey)[\(index)]"

        for key in requiredKeys.sorted() where eventObject[key] == nil {
            throw MixedBearerFixtureRunnerError.invalidFixture(
                relativePath: relativePath,
                detail: "\(context) missing required telemetry envelope key \(key) (per schema.json telemetryEvent.required)"
            )
        }
    }

    func assertEventSequenceMonotonicByEncounterAttempt(
        events: [MixedBearerFixtureTestSupport.TelemetryFixtureEvent],
        relativePath: String
    ) throws {
        let groupedByAttempt = Dictionary(grouping: events, by: { $0.encounterAttemptID })

        for encounterAttemptID in groupedByAttempt.keys.sorted() {
            guard let attemptEvents = groupedByAttempt[encounterAttemptID] else {
                continue
            }
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

    func assertExpectedTerminalOutcomeStopClassCoherence(
        fixture: MixedBearerFixtureTestSupport.FixtureDocument,
        relativePath: String
    ) throws {
        let expected = fixture.expected
        let expectedRefusalReason = expected.refusalReason

        switch expectedRefusalReason {
        case .timeScopeStale?, .timeScopeExpired?, .timeScopeInvalid?:
            guard expected.terminalOutcome == .policyStop else {
                throw MixedBearerFixtureRunnerError.invalidFixture(
                    relativePath: relativePath,
                    detail: "expected.refusalReason=\(expectedRefusalReason?.rawValue ?? "nil") requires expected.terminalOutcome=policy-stop"
                )
            }
        case .resumeTokenInvalid?:
            guard expected.terminalOutcome == .failedEnd else {
                throw MixedBearerFixtureRunnerError.invalidFixture(
                    relativePath: relativePath,
                    detail: "expected.refusalReason=resume_token_invalid requires expected.terminalOutcome=failed-end"
                )
            }
        default:
            break
        }

        guard let terminalOutcome = expected.terminalOutcome else { return }

        if terminalOutcome == .policyStop {
            if expected.outcome == .stop {
                guard let stopClass = expected.stopClass else {
                    throw MixedBearerFixtureRunnerError.invalidFixture(
                        relativePath: relativePath,
                        detail: "expected.outcome=stop with expected.terminalOutcome=policy-stop requires expected.stopClass=policy_stop"
                    )
                }
                guard stopClass == .policyStop else {
                    throw MixedBearerFixtureRunnerError.invalidFixture(
                        relativePath: relativePath,
                        detail: "expected.terminalOutcome=policy-stop requires expected.stopClass=policy_stop; got \(stopClass.rawValue)"
                    )
                }
            } else if let stopClass = expected.stopClass, stopClass != .policyStop {
                throw MixedBearerFixtureRunnerError.invalidFixture(
                    relativePath: relativePath,
                    detail: "expected.terminalOutcome=policy-stop allows expected.stopClass only as policy_stop; got \(stopClass.rawValue)"
                )
            }
        }

        if expected.stopClass == .policyStop, terminalOutcome != .policyStop {
            throw MixedBearerFixtureRunnerError.invalidFixture(
                relativePath: relativePath,
                detail: "expected.stopClass=policy_stop requires expected.terminalOutcome=policy-stop"
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
