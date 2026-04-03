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
        let encounter: [TelemetryEvent]
        let forwarding: [TelemetryEvent]
        let adminRecord: [TelemetryEvent]
        let declaredExtensionRefusalReasons: [ExtensionRefusalReasonDeclaration]?
        let extensionRefusalReasonsDeclaredInManifest: Bool?
        let expected: ExpectedOutcome

        enum CodingKeys: String, CodingKey {
            case schemaVersion
            case fixtureID
            case nowUnixMs
            case timeScope
            case encounter
            case forwarding
            case adminRecord = "admin_record"
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
        let terminalOutcome: String?
        let stopClass: String?
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

    static func decodeTelemetryEvent(
        rawObject: [String: Any],
        relativePath: String,
        laneKey: String,
        index: Int
    ) throws -> TelemetryEvent {
        let context = "\(relativePath):\(laneKey)[\(index)]"
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: rawObject, options: [])
        } catch {
            throw FixtureError.invalidFixture(relativePath: context, detail: "Event object could not be re-encoded for decoding: \(error)")
        }

        do {
            return try JSONDecoder().decode(TelemetryEvent.self, from: data)
        } catch {
            throw FixtureError.invalidFixture(relativePath: context, detail: "Event failed TelemetryEvent decode: \(error)")
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
