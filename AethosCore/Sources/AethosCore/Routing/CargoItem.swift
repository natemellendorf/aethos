import Foundation

public enum CargoItem: Equatable, Sendable {
    case envelope(Data)          // canonical bytes
    case manifest(Data)          // canonical bytes
    case chunk(id: Data, bytes: Data)
    case receipt(Data)           // canonical bytes
    case inventory(Data)         // canonical bytes
    case inventoryRequest(Data)  // canonical bytes

    public enum Priority: UInt8, Comparable, Sendable {
        case receipt = 5
        case inventoryRequest = 4
        case inventory = 3
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
        case .inventoryRequest:
            return .inventoryRequest
        case .inventory:
            return .inventory
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
        case let .inventory(bytes):
            return bytes.count
        case let .inventoryRequest(bytes):
            return bytes.count
        case let .chunk(_, bytes):
            // With framing, chunks may be transferred in parts; use a conservative
            // per-session planning size so routers can make progress with small budgets.
            return min(bytes.count, Self.defaultChunkPartBudgetBytes)
        }
    }

    public static let defaultChunkPartBudgetBytes: Int = 3000
}

public struct SessionBudget: Equatable, Sendable {
    public let maxBytes: Int
    public let maxItems: Int

    public init(maxBytes: Int, maxItems: Int) {
        self.maxBytes = maxBytes
        self.maxItems = maxItems
    }
}
