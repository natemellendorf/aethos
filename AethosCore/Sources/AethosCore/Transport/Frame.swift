import Foundation

public struct Frame: Equatable, Sendable {
    public enum FrameError: Swift.Error, Equatable {
        case invalidMagic
        case unsupportedVersion(UInt8)
        case invalidLength
        case truncated
    }

    public static let magic: UInt32 = 0x4154_4853 // "ATHS"
    public static let currentVersion: UInt8 = 1

    public let version: UInt8
    public let type: UInt8
    public let id: Data
    public let partIndex: UInt16
    public let partCount: UInt16
    public let payload: Data

    public init(
        version: UInt8 = Frame.currentVersion,
        type: UInt8,
        id: Data,
        partIndex: UInt16,
        partCount: UInt16,
        payload: Data
    ) {
        self.version = version
        self.type = type
        self.id = id
        self.partIndex = partIndex
        self.partCount = partCount
        self.payload = payload
    }

    // Header:
    // magic(4) + version(1) + type(1) + idLen(2) + partIndex(2) + partCount(2) + payloadLen(4)
    public var sizeBytes: Int {
        4 + 1 + 1 + 2 + 2 + 2 + 4 + id.count + payload.count
    }

    public func encode() -> Data {
        var out = Data()
        out.reserveCapacity(sizeBytes)

        out.appendUInt32(Self.magic)
        out.appendUInt8(version)
        out.appendUInt8(type)
        out.appendUInt16(UInt16(id.count))
        out.appendUInt16(partIndex)
        out.appendUInt16(partCount)
        out.appendUInt32(UInt32(payload.count))
        out.append(id)
        out.append(payload)
        return out
    }

    public static func decode(_ data: Data) throws -> Frame {
        var r = Reader(data)
        guard let magic = r.readUInt32(), magic == Self.magic else { throw FrameError.invalidMagic }
        guard let version = r.readUInt8() else { throw FrameError.truncated }
        guard version == Self.currentVersion else { throw FrameError.unsupportedVersion(version) }
        guard let type = r.readUInt8() else { throw FrameError.truncated }
        guard let idLen = r.readUInt16() else { throw FrameError.truncated }
        guard let partIndex = r.readUInt16() else { throw FrameError.truncated }
        guard let partCount = r.readUInt16() else { throw FrameError.truncated }
        guard let payloadLen = r.readUInt32() else { throw FrameError.truncated }

        // Basic checks.
        if partCount == 0 { throw FrameError.invalidLength }
        if partIndex >= partCount { throw FrameError.invalidLength }
        if idLen == 0 { throw FrameError.invalidLength }
        if payloadLen > 16 * 1024 * 1024 { throw FrameError.invalidLength }

        guard let id = r.readData(count: Int(idLen)) else { throw FrameError.truncated }
        guard let payload = r.readData(count: Int(payloadLen)) else { throw FrameError.truncated }
        if !r.isAtEnd { throw FrameError.invalidLength }

        return Frame(version: version, type: type, id: id, partIndex: partIndex, partCount: partCount, payload: payload)
    }
}

private extension Data {
    mutating func appendUInt8(_ value: UInt8) {
        append(value)
    }

    mutating func appendUInt16(_ value: UInt16) {
        var v = value.bigEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func appendUInt32(_ value: UInt32) {
        var v = value.bigEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}

private struct Reader {
    private let data: Data
    private var offset: Int = 0

    init(_ data: Data) {
        self.data = data
    }

    var isAtEnd: Bool { offset >= data.count }

    mutating func readUInt8() -> UInt8? {
        guard offset + 1 <= data.count else { return nil }
        let v = data[offset]
        offset += 1
        return v
    }

    mutating func readUInt16() -> UInt16? {
        guard let b0 = readUInt8(), let b1 = readUInt8() else { return nil }
        return (UInt16(b0) << 8) | UInt16(b1)
    }

    mutating func readUInt32() -> UInt32? {
        guard let b0 = readUInt8(), let b1 = readUInt8(), let b2 = readUInt8(), let b3 = readUInt8() else { return nil }
        return (UInt32(b0) << 24) | (UInt32(b1) << 16) | (UInt32(b2) << 8) | UInt32(b3)
    }

    mutating func readData(count: Int) -> Data? {
        guard count >= 0, offset + count <= data.count else { return nil }
        let slice = data[offset..<offset + count]
        offset += count
        return Data(slice)
    }
}
