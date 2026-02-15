import Foundation

public enum CLIJSON {
    // Manual JSON serialization for stable, sorted output.
    // Keep this as the single implementation so snapshot tests can depend on it.
    public static func serializeJSON(_ value: Any, indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        let innerPad = String(repeating: "  ", count: indent + 1)

        if let dict = value as? [String: Any] {
            if dict.isEmpty { return "{}" }
            let keys = dict.keys.sorted()
            var lines: [String] = []
            for key in keys {
                let val = serializeJSON(dict[key]!, indent: indent + 1)
                lines.append("\(innerPad)\(escapeJSONString(key)): \(val)")
            }
            return "{\n\(lines.joined(separator: ",\n"))\n\(pad)}"
        }

        if let arr = value as? [[String: Any]] {
            if arr.isEmpty { return "[]" }
            var items: [String] = []
            for item in arr {
                items.append("\(innerPad)\(serializeJSON(item, indent: indent + 1))")
            }
            return "[\n\(items.joined(separator: ",\n"))\n\(pad)]"
        }

        if let arr = value as? [Any] {
            if arr.isEmpty { return "[]" }
            var items: [String] = []
            for item in arr {
                items.append("\(innerPad)\(serializeJSON(item, indent: indent + 1))")
            }
            return "[\n\(items.joined(separator: ",\n"))\n\(pad)]"
        }

        if let s = value as? String {
            return escapeJSONString(s)
        }

        if value is NSNull {
            return "null"
        }

        if let b = value as? Bool {
            return b ? "true" : "false"
        }

        if let n = value as? Int64 {
            return "\(n)"
        }

        if let n = value as? Int32 {
            return "\(n)"
        }

        if let n = value as? Int {
            return "\(n)"
        }

        return "null"
    }

    private static func escapeJSONString(_ s: String) -> String {
        var out = "\""
        for c in s {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(c)
            }
        }
        out += "\""
        return out
    }
}
