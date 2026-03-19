import Crypto
import Foundation

struct VectorFile: Decodable {
    let envelope: Envelope
}

struct Envelope: Decodable {
    let to_wayfarer_id: String
    let manifest_id: String
    let body_utf8: String
    let author_pubkey: String
    let author_sig: String
}

struct Output: Encodable {
    let canonical_cbor_hex: String
    let item_id_hex: String
    let envelope_b64: String
}

enum RunnerError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let message):
            return message
        }
    }
}

func main() -> Int32 {
    let args = CommandLine.arguments
    guard args.count == 3 else {
        writeError("usage: swift_runner encode-envelope <vector-file>")
        return 1
    }
    guard args[1] == "encode-envelope" else {
        writeError("unsupported command: \(args[1])")
        return 1
    }

    do {
        let url = URL(fileURLWithPath: args[2])
        let data = try Data(contentsOf: url)
        let vector = try JSONDecoder().decode(VectorFile.self, from: data)
        try validateEnvelope(vector.envelope)

        let canonical = try encodeCanonicalEnvelope(vector.envelope)
        let itemIDHex = sha256Hex(canonical)
        let output = Output(
            canonical_cbor_hex: hexEncode(canonical),
            item_id_hex: itemIDHex,
            envelope_b64: base64URLNoPadding(canonical)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let outputData = try encoder.encode(output)
        if let outputString = String(data: outputData, encoding: .utf8) {
            print(outputString)
        } else {
            throw RunnerError.message("failed to encode output JSON")
        }
        return 0
    } catch {
        writeError("error: \(error)")
        return 1
    }
}

func validateEnvelope(_ envelope: Envelope) throws {
    guard envelope.to_wayfarer_id.count == 64, isLowerHex(envelope.to_wayfarer_id) else {
        throw RunnerError.message("envelope.to_wayfarer_id must be 64 lowercase hex chars")
    }
    guard envelope.manifest_id.count == 64, isLowerHex(envelope.manifest_id) else {
        throw RunnerError.message("envelope.manifest_id must be 64 lowercase hex chars")
    }
    guard envelope.author_pubkey.count == 64, isLowerHex(envelope.author_pubkey) else {
        throw RunnerError.message("envelope.author_pubkey must be 64 lowercase hex chars")
    }
    guard envelope.author_sig.count == 128, isLowerHex(envelope.author_sig) else {
        throw RunnerError.message("envelope.author_sig must be 128 lowercase hex chars")
    }
}

func isLowerHex(_ value: String) -> Bool {
    return value.unicodeScalars.allSatisfy { scalar in
        switch scalar.value {
        case 48...57, 97...102:
            return true
        default:
            return false
        }
    }
}

func encodeCanonicalEnvelope(_ envelope: Envelope) throws -> Data {
    let body = Data(envelope.body_utf8.utf8)
    let manifestID = try decodeHex(envelope.manifest_id)
    let toWayfarerID = try decodeHex(envelope.to_wayfarer_id)
    let authorPubkey = try decodeHex(envelope.author_pubkey)
    let authorSig = try decodeHex(envelope.author_sig)

    var entries: [(key: String, value: Data)] = [
        ("to_wayfarer_id", toWayfarerID),
        ("manifest_id", manifestID),
        ("author_pubkey", authorPubkey),
        ("author_sig", authorSig),
        ("body", body),
    ]

    entries.sort { lhs, rhs in
        if lhs.key.count != rhs.key.count {
            return lhs.key.count < rhs.key.count
        }
        return lhs.key < rhs.key
    }

    guard entries.count < 24 else {
        throw RunnerError.message("map too large for compatibility runner")
    }

    var out = Data()
    out.append(0xa0 | UInt8(entries.count))
    for entry in entries {
        out.append(try encodeText(entry.key))
        out.append(try encodeBytes(entry.value))
    }
    return out
}

func encodeText(_ value: String) throws -> Data {
    let bytes = Data(value.utf8)
    var out = Data()

    switch bytes.count {
    case 0..<24:
        out.append(0x60 | UInt8(bytes.count))
    case 24..<256:
        out.append(0x78)
        out.append(UInt8(bytes.count))
    case 256..<65536:
        out.append(0x79)
        out.append(UInt8((bytes.count >> 8) & 0xff))
        out.append(UInt8(bytes.count & 0xff))
    default:
        throw RunnerError.message("string too long for compatibility runner")
    }

    out.append(bytes)
    return out
}

func encodeBytes(_ value: Data) throws -> Data {
    var out = Data()

    switch value.count {
    case 0..<24:
        out.append(0x40 | UInt8(value.count))
    case 24..<256:
        out.append(0x58)
        out.append(UInt8(value.count))
    case 256..<65536:
        out.append(0x59)
        out.append(UInt8((value.count >> 8) & 0xff))
        out.append(UInt8(value.count & 0xff))
    default:
        throw RunnerError.message("byte string too long for compatibility runner")
    }

    out.append(value)
    return out
}

func decodeHex(_ value: String) throws -> Data {
    guard value.count % 2 == 0 else {
        throw RunnerError.message("hex value must have even length")
    }
    let scalars = Array(value.unicodeScalars)
    var out = Data(capacity: scalars.count / 2)
    var idx = 0
    while idx < scalars.count {
        let high = try hexValue(scalars[idx])
        let low = try hexValue(scalars[idx + 1])
        out.append((high << 4) | low)
        idx += 2
    }
    return out
}

func hexValue(_ scalar: UnicodeScalar) throws -> UInt8 {
    switch scalar.value {
    case 48...57:
        return UInt8(scalar.value - 48)
    case 97...102:
        return UInt8(scalar.value - 97 + 10)
    default:
        throw RunnerError.message("hex value must use lowercase digits")
    }
}

func hexEncode(_ data: Data) -> String {
    var out = String()
    out.reserveCapacity(data.count * 2)
    for byte in data {
        out.append(nibble((byte >> 4) & 0x0f))
        out.append(nibble(byte & 0x0f))
    }
    return out
}

func nibble(_ value: UInt8) -> Character {
    let scalar: UnicodeScalar
    switch value {
    case 0...9:
        scalar = UnicodeScalar(48 + value)
    default:
        scalar = UnicodeScalar(87 + value)
    }
    return Character(scalar)
}

func sha256Hex(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
}

func base64URLNoPadding(_ data: Data) -> String {
    var encoded = data.base64EncodedString()
    encoded = encoded.replacingOccurrences(of: "+", with: "-")
    encoded = encoded.replacingOccurrences(of: "/", with: "_")
    return encoded.replacingOccurrences(of: "=", with: "")
}

func writeError(_ message: String) {
    if let data = "\(message)\n".data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

exit(main())
