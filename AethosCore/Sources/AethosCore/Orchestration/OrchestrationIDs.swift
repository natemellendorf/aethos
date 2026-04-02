import Foundation

public struct EncounterContextID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init() {
        self.init(rawValue: UUID().uuidString.lowercased())
    }
}

public struct EncounterInstanceID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init() {
        self.init(rawValue: UUID().uuidString.lowercased())
    }
}

public struct EncounterAttemptID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init() {
        self.init(rawValue: UUID().uuidString.lowercased())
    }
}

public struct BearerID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init() {
        self.init(rawValue: UUID().uuidString.lowercased())
    }
}

public struct EventID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init() {
        self.init(rawValue: UUID().uuidString.lowercased())
    }
}
