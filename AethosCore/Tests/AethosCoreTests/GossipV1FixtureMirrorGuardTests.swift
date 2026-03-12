import Foundation
import XCTest

/// CI guard: the canonical repo-root fixtures must match the SwiftPM test-resources mirror.
final class GossipV1FixtureMirrorGuardTests: XCTestCase {
    func testCanonicalGossipV1FixturesMatchSwiftPMResourcesMirror_byteForByte() throws {
        let repoRoot = try RepoRootLocator.repoRoot(near: #filePath)

        let canonical = repoRoot
            .appendingPathComponent("Fixtures/Protocol/gossip-v1", isDirectory: true)
        let mirror = repoRoot
            .appendingPathComponent(
                "AethosCore/Tests/AethosCoreTests/Resources/Fixtures/Protocol/gossip-v1",
                isDirectory: true
            )

        let canonicalFiles = try FixtureTree.regularFilesByRelativePath(under: canonical)
        let mirrorFiles = try FixtureTree.regularFilesByRelativePath(under: mirror)

        let canonicalPaths = Set(canonicalFiles.keys)
        let mirrorPaths = Set(mirrorFiles.keys)

        let missingInMirror = (canonicalPaths.subtracting(mirrorPaths)).sorted()
        let extraInMirror = (mirrorPaths.subtracting(canonicalPaths)).sorted()

        if !missingInMirror.isEmpty || !extraInMirror.isEmpty {
            XCTFail(
                FixtureTree.formatPathSetMismatch(
                    canonicalRoot: canonical,
                    mirrorRoot: mirror,
                    missingInMirror: missingInMirror,
                    extraInMirror: extraInMirror
                )
            )
            return
        }

        var mismatches: [String] = []
        for relativePath in canonicalPaths.sorted() {
            guard let canonicalURL = canonicalFiles[relativePath], let mirrorURL = mirrorFiles[relativePath] else {
                continue
            }

            let canonicalBytes = try Data(contentsOf: canonicalURL)
            let mirrorBytes = try Data(contentsOf: mirrorURL)
            if canonicalBytes != mirrorBytes {
                mismatches.append(relativePath)
            }
        }

        if !mismatches.isEmpty {
            XCTFail(
                FixtureTree.formatByteMismatch(
                    canonicalRoot: canonical,
                    mirrorRoot: mirror,
                    relativePaths: mismatches
                )
            )
        }
    }
}

private enum RepoRootLocator {
    enum Error: Swift.Error, CustomStringConvertible {
        case repoRootNotFound(startingAt: URL)

        var description: String {
            switch self {
            case .repoRootNotFound(let startingAt):
                return "Failed to locate repo root by walking upward from: \(startingAt.path)"
            }
        }
    }

    /// Walk upward from a source file path until we find a directory that contains
    /// both `Package.swift` and `Fixtures/Protocol/gossip-v1`.
    static func repoRoot(near filePath: String) throws -> URL {
        var candidate = URL(fileURLWithPath: filePath).deletingLastPathComponent()

        while true {
            let packageSwift = candidate.appendingPathComponent("Package.swift", isDirectory: false)
            let fixturesDir = candidate.appendingPathComponent("Fixtures/Protocol/gossip-v1", isDirectory: true)

            if FileManager.default.fileExists(atPath: packageSwift.path),
               FileManager.default.fileExists(atPath: fixturesDir.path)
            {
                return candidate
            }

            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path {
                throw Error.repoRootNotFound(startingAt: URL(fileURLWithPath: filePath))
            }
            candidate = parent
        }
    }
}

private enum FixtureTree {
    enum Error: Swift.Error, CustomStringConvertible {
        case missingDirectory(URL)
        case failedToEnumerate(URL)
        case invalidRelativePath(file: URL, root: URL)

        var description: String {
            switch self {
            case .missingDirectory(let url):
                return "Missing directory: \(url.path)"
            case .failedToEnumerate(let url):
                return "Failed to enumerate directory: \(url.path)"
            case .invalidRelativePath(let file, let root):
                return "Failed to compute relative path for \(file.path) under \(root.path)"
            }
        }
    }

    static func regularFilesByRelativePath(under root: URL) throws -> [String: URL] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw Error.missingDirectory(root)
        }

        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            throw Error.failedToEnumerate(root)
        }

        var out: [String: URL] = [:]
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }

            let relativePath = try makeRelativePath(fileURL: fileURL, root: root)
            out[relativePath] = fileURL
        }
        return out
    }

    private static func makeRelativePath(fileURL: URL, root: URL) throws -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path

        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard filePath.hasPrefix(prefix) else {
            throw Error.invalidRelativePath(file: fileURL, root: root)
        }
        return String(filePath.dropFirst(prefix.count))
    }

    static func formatPathSetMismatch(
        canonicalRoot: URL,
        mirrorRoot: URL,
        missingInMirror: [String],
        extraInMirror: [String]
    ) -> String {
        var parts: [String] = []
        parts.append("Fixture mirror drift detected.")
        parts.append("Canonical: \(canonicalRoot.path)")
        parts.append("Mirror:    \(mirrorRoot.path)")

        if !missingInMirror.isEmpty {
            parts.append("Missing in mirror (present in canonical):")
            parts.append(contentsOf: missingInMirror.map { "  - \($0)" })
        }

        if !extraInMirror.isEmpty {
            parts.append("Extra in mirror (absent in canonical):")
            parts.append(contentsOf: extraInMirror.map { "  - \($0)" })
        }

        return parts.joined(separator: "\n")
    }

    static func formatByteMismatch(
        canonicalRoot: URL,
        mirrorRoot: URL,
        relativePaths: [String]
    ) -> String {
        var parts: [String] = []
        parts.append("Fixture mirror drift detected: file contents differ.")
        parts.append("Canonical: \(canonicalRoot.path)")
        parts.append("Mirror:    \(mirrorRoot.path)")
        parts.append("Mismatched files:")
        parts.append(contentsOf: relativePaths.sorted().map { "  - \($0)" })
        return parts.joined(separator: "\n")
    }
}
