import Foundation

public enum CargoItem: Equatable, Sendable {
    case envelope(Data)   // canonical bytes
    case manifest(Data)   // canonical bytes
    case chunk(id: Data, bytes: Data)
    case receipt(Data)    // canonical bytes

    public enum Priority: UInt8, Comparable, Sendable {
        case receipt = 3
        case metadata = 2
        case chunk = 1

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public var priority: Priority {
        switch self {
        case .receipt:
            return .receipt
        case .envelope, .manifest:
            return .metadata
        case .chunk:
            return .chunk
        }
    }

    public var sizeBytes: Int {
        switch self {
        case let .envelope(bytes):
            return bytes.count
        case let .manifest(bytes):
            return bytes.count
        case let .receipt(bytes):
            return bytes.count
        case let .chunk(_, bytes):
            return bytes.count
        }
    }
}

public struct SessionBudget: Equatable, Sendable {
    public let maxBytes: Int
    public let maxItems: Int

    public init(maxBytes: Int, maxItems: Int) {
        self.maxBytes = maxBytes
        self.maxItems = maxItems
    }
}
