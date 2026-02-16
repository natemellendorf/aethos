import Foundation
import Testing

final class SnapshotHarness {
    private let fileManager = FileManager.default
    private let record: Bool

    init(record: Bool = ProcessInfo.processInfo.environment["AETHOS_SNAPSHOT_RECORD"] == "1") {
        self.record = record
    }

    func assertSnapshot(
        name: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ build: () throws -> String
    ) throws {
        let snapshotsDir = snapshotsDirectory(testFile: file)
        try fileManager.createDirectory(at: snapshotsDir, withIntermediateDirectories: true)
        let snapshotURL = snapshotsDir.appendingPathComponent("\(name).snap", isDirectory: false)

        let got = normalize(try build())

        if !fileManager.fileExists(atPath: snapshotURL.path) {
            if record {
                try got.write(to: snapshotURL, atomically: true, encoding: .utf8)
                return
            }
            Issue.record("Missing snapshot: \(snapshotURL.path) (set AETHOS_SNAPSHOT_RECORD=1 to record)")
            return
        }

        if record {
            try got.write(to: snapshotURL, atomically: true, encoding: .utf8)
            return
        }

        let expected = try String(contentsOf: snapshotURL, encoding: .utf8)
        if got != expected {
            let diff = unifiedDiff(expected: expected, got: got)
            Issue.record("Snapshot mismatch: \(name)\n\n\(diff)")
        }
    }

    private func snapshotsDirectory(testFile: StaticString) -> URL {
        let testPath = String(describing: testFile)
        // Tests/AethosCLITests/<file>.swift -> Tests/AethosCLITests/Snapshots
        let fileURL = URL(fileURLWithPath: testPath)
        return fileURL.deletingLastPathComponent().appendingPathComponent("Snapshots", isDirectory: true)
    }

    private func normalize(_ s: String) -> String {
        // Ensure stable trailing newline and avoid \\r\\n issues.
        let unix = s.replacingOccurrences(of: "\r\n", with: "\n")
        return unix.hasSuffix("\n") ? unix : (unix + "\n")
    }

    private func unifiedDiff(expected: String, got: String) -> String {
        // Minimal, readable diff (line-based); avoids external tools.
        let e = expected.split(separator: "\n", omittingEmptySubsequences: false)
        let g = got.split(separator: "\n", omittingEmptySubsequences: false)
        var out: [String] = []
        out.append("--- expected")
        out.append("+++ got")

        let maxCount = Swift.max(e.count, g.count)
        for i in 0..<maxCount {
            let el = i < e.count ? String(e[i]) : nil
            let gl = i < g.count ? String(g[i]) : nil
            if el == gl { continue }
            if let el { out.append("-\(el)") }
            if let gl { out.append("+\(gl)") }
        }
        return out.joined(separator: "\n")
    }
}
