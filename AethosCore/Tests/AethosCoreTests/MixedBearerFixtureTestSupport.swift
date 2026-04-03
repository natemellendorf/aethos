import Foundation
@testable import AethosCore

enum MixedBearerFixtureTestSupport {
    static let fixtureRootResourcePath = "Fixtures/Orchestration/mixed-bearer"
    static let telemetryLaneKeys = ["encounter", "forwarding", "admin_record"]

    enum FixtureError: Swift.Error, CustomStringConvertible {
        case missingResource(relativePath: String)
        case invalidFixture(relativePath: String, detail: String)

        var description: String {
            switch self {
            case .missingResource(let relativePath):
                return "Missing mixed-bearer fixture resource: \(relativePath)"
            case .invalidFixture(let relativePath, let detail):
                return "Invalid mixed-bearer fixture (\(relativePath)): \(detail)"
            }
        }
    }

    struct Manifest: Decodable {
        let manifestVersion: UInt64
        let suiteID: String
        let schema: String
        let schemaVersion: String
        let lanes: [String]
        let fixtures: [FixtureReference]
        let extensions: ManifestExtensions?
    }

    struct ManifestExtensions: Decodable {
        let declaredExtensionRefusalReasons: [ExtensionRefusalReasonDeclaration]
    }

    struct FixtureReference: Decodable {
        let lane: String
        let fixture: String
        let locksIn: String

        var normalizedFixtureRelativePath: String {
            Self.normalizePath(fixture)
        }

        private static func normalizePath(_ path: String) -> String {
            var normalized = path
            while normalized.hasPrefix("./") {
                normalized.removeFirst(2)
            }
            while normalized.hasPrefix("/") {
                normalized.removeFirst()
            }
            return normalized
        }
    }

    struct FixtureDocument: Decodable {
        let schemaVersion: String
        let fixtureID: String
        let nowUnixMs: UInt64
        let timeScope: FixtureTimeScope
        let declaredExtensionRefusalReasons: [ExtensionRefusalReasonDeclaration]?
        let extensionRefusalReasonsDeclaredInManifest: Bool?
        let expected: ExpectedOutcome

        enum CodingKeys: String, CodingKey {
            case schemaVersion
            case fixtureID
            case nowUnixMs
            case timeScope
            case declaredExtensionRefusalReasons
            case extensionRefusalReasonsDeclaredInManifest
            case expected
        }
    }

    struct FixtureTimeScope: Decodable {
        let observedAtUnixMs: UInt64
        let staleAfterUnixMs: UInt64
        let validUntilUnixMs: UInt64?
    }

    struct ExtensionRefusalReasonDeclaration: Decodable {
        let code: String
        let layer: TelemetryLayer
        let description: String
    }

    struct ExpectedOutcome: Decodable {
        let outcome: Outcome
        let refusalReason: RefusalReason?
        let terminalOutcome: TerminalOutcome?
        let stopClass: EncounterStopClass?
    }

    struct TelemetryFixtureEvent: Decodable {
        let contractVersion: UInt8
        let eventID: String
        let layer: TelemetryLayer
        let eventType: String
        let eventSequence: UInt64
        let occurredAtUnixMs: UInt64
        let encounterContextID: String
        let encounterInstanceID: String
        let encounterAttemptID: String
        let bearerID: String?
        let payload: [String: JSONValue]
    }

    /// Minimal schema-driven checks loaded directly from schema.json.
    ///
    /// This is intentionally a subset (not a full JSON Schema engine):
    /// - root required keys
    /// - telemetry event required keys
    /// - expected.terminalOutcome allowed tokens
    /// - expected.stopClass allowed tokens
    struct SchemaSubsetValidationRules {
        let rootRequiredKeys: Set<String>
        let telemetryEventRequiredKeys: Set<String>
        let terminalOutcomeTokens: Set<String>
        let stopClassTokens: Set<String>
    }

    enum Outcome: String, Decodable {
        case accept
        case reject
        case stop
        case deferred = "defer"
    }

    static func loadManifest() throws -> Manifest {
        try decodeJSON(Manifest.self, relativePath: "manifest.json")
    }

    static func loadFixture(relativePath: String) throws -> FixtureDocument {
        try decodeJSON(FixtureDocument.self, relativePath: relativePath)
    }

    static func loadFixtureJSON(relativePath: String) throws -> [String: Any] {
        let data = try fixtureData(relativePath)
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dictionary = object as? [String: Any] else {
            throw FixtureError.invalidFixture(relativePath: relativePath, detail: "Top-level JSON must be an object")
        }
        return dictionary
    }

    static func loadSchemaSubsetValidationRules() throws -> SchemaSubsetValidationRules {
        let schemaPath = "schema.json"
        let schema = try loadFixtureJSON(relativePath: schemaPath)

        let rootRequired = try requiredStringSet(
            in: schema,
            key: "required",
            relativePath: schemaPath,
            context: "schema.required"
        )

        let defs = try nestedObject(
            in: schema,
            key: "$defs",
            relativePath: schemaPath,
            context: "schema.$defs"
        )

        let telemetryEvent = try nestedObject(
            in: defs,
            key: "telemetryEvent",
            relativePath: schemaPath,
            context: "schema.$defs.telemetryEvent"
        )
        let telemetryEventRequired = try requiredStringSet(
            in: telemetryEvent,
            key: "required",
            relativePath: schemaPath,
            context: "schema.$defs.telemetryEvent.required"
        )

        let expectedOutcome = try nestedObject(
            in: defs,
            key: "expectedOutcome",
            relativePath: schemaPath,
            context: "schema.$defs.expectedOutcome"
        )
        let expectedProperties = try nestedObject(
            in: expectedOutcome,
            key: "properties",
            relativePath: schemaPath,
            context: "schema.$defs.expectedOutcome.properties"
        )

        let terminalOutcome = try nestedObject(
            in: expectedProperties,
            key: "terminalOutcome",
            relativePath: schemaPath,
            context: "schema.$defs.expectedOutcome.properties.terminalOutcome"
        )
        let terminalOutcomeTokens = try requiredStringSet(
            in: terminalOutcome,
            key: "enum",
            relativePath: schemaPath,
            context: "schema.$defs.expectedOutcome.properties.terminalOutcome.enum"
        )

        let stopClass = try nestedObject(
            in: expectedProperties,
            key: "stopClass",
            relativePath: schemaPath,
            context: "schema.$defs.expectedOutcome.properties.stopClass"
        )
        let stopClassTokens = try requiredStringSet(
            in: stopClass,
            key: "enum",
            relativePath: schemaPath,
            context: "schema.$defs.expectedOutcome.properties.stopClass.enum"
        )

        return SchemaSubsetValidationRules(
            rootRequiredKeys: rootRequired,
            telemetryEventRequiredKeys: telemetryEventRequired,
            terminalOutcomeTokens: terminalOutcomeTokens,
            stopClassTokens: stopClassTokens
        )
    }

    static func decodeTelemetryEvent(
        rawObject: [String: Any],
        relativePath: String,
        laneKey: String,
        index: Int
    ) throws -> TelemetryFixtureEvent {
        let context = "\(relativePath):\(laneKey)[\(index)]"
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: rawObject, options: [])
        } catch {
            throw FixtureError.invalidFixture(relativePath: context, detail: "Event object could not be re-encoded for decoding: \(error)")
        }

        do {
            return try JSONDecoder().decode(TelemetryFixtureEvent.self, from: data)
        } catch {
            throw FixtureError.invalidFixture(relativePath: context, detail: "Event failed mixed-bearer telemetry decode: \(error)")
        }
    }

    static func fixtureData(_ relativePath: String) throws -> Data {
        let url = try fixtureURL(relativePath)
        return try Data(contentsOf: url)
    }

    static func fixtureURL(_ relativePath: String) throws -> URL {
        let normalizedPath = normalizeResourcePath(relativePath)
        guard !normalizedPath.isEmpty else {
            throw FixtureError.missingResource(relativePath: "\(fixtureRootResourcePath)/")
        }

        let resourcePath = "\(fixtureRootResourcePath)/\(normalizedPath)"
        guard let url = Bundle.module.url(forResource: resourcePath, withExtension: nil) else {
            throw FixtureError.missingResource(relativePath: resourcePath)
        }
        return url
    }

    private static func decodeJSON<T: Decodable>(_ type: T.Type, relativePath: String) throws -> T {
        let data = try fixtureData(relativePath)
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw FixtureError.invalidFixture(relativePath: relativePath, detail: "JSON decode failed: \(error)")
        }
    }

    private static func nestedObject(
        in dictionary: [String: Any],
        key: String,
        relativePath: String,
        context: String
    ) throws -> [String: Any] {
        guard let nested = dictionary[key] as? [String: Any] else {
            throw FixtureError.invalidFixture(
                relativePath: relativePath,
                detail: "\(context) is missing or is not an object"
            )
        }
        return nested
    }

    private static func requiredStringSet(
        in dictionary: [String: Any],
        key: String,
        relativePath: String,
        context: String
    ) throws -> Set<String> {
        guard let values = dictionary[key] as? [String], !values.isEmpty else {
            throw FixtureError.invalidFixture(
                relativePath: relativePath,
                detail: "\(context) is missing or is not a non-empty string array"
            )
        }
        return Set(values)
    }

    private static func normalizeResourcePath(_ path: String) -> String {
        var normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.hasPrefix("./") {
            normalized.removeFirst(2)
        }
        while normalized.hasPrefix("/") {
            normalized.removeFirst()
        }
        return normalized
    }
}
