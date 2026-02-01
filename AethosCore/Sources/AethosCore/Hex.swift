import Foundation

public enum Hex {
    public static func encode(_ data: Data) -> String {
        let alphabet: [UInt8] = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(data.count * 2)

        for byte in data {
            out.append(alphabet[Int(byte >> 4)])
            out.append(alphabet[Int(byte & 0x0f)])
        }

        return String(decoding: out, as: UTF8.self)
    }

    public static func decode(_ hex: String) -> Data? {
        let bytes = Array(hex.utf8)
        guard bytes.count % 2 == 0 else { return nil }

        func nybble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48 // 0-9
            case 97...102: return c - 87 // a-f
            case 65...70: return c - 55 // A-F
            default: return nil
            }
        }

        var out = Data()
        out.reserveCapacity(bytes.count / 2)

        var i = 0
        while i < bytes.count {
            guard let hi = nybble(bytes[i]), let lo = nybble(bytes[i + 1]) else { return nil }
            out.append((hi << 4) | lo)
            i += 2
        }

        return out
    }
}

public extension Data {
    var hexString: String { Hex.encode(self) }
}
