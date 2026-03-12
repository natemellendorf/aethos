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
            let canonicalURL = try XCTUnwrap(
                canonicalFiles[relativePath],
                "Unexpected state: canonical fixtures missing URL for relative path: \(relativePath)"
            )
            let mirrorURL = try XCTUnwrap(
                mirrorFiles[relativePath],
                "Unexpected state: mirror fixtures missing URL for relative path: \(relativePath)"
            )

            if try !FixtureTree.filesAreEqual(canonicalURL, mirrorURL) {
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
                return "Failed to locate repo root by walking upward from: \(startingAt.path). Markers searched: Package.swift (file) and Fixtures/Protocol/gossip-v1 (directory)."
            }
        }
    }

    /// Walk upward from a source file path until we find a directory that contains
    /// both `Package.swift` and `Fixtures/Protocol/gossip-v1`.
    static func repoRoot(near filePath: String) throws -> URL {
        let startingDirectory = URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()
            .standardizedFileURL

        var candidate = startingDirectory
        let fileManager = FileManager.default

        while true {
            let packageSwift = candidate.appendingPathComponent("Package.swift", isDirectory: false)
            let fixturesDir = candidate.appendingPathComponent("Fixtures/Protocol/gossip-v1", isDirectory: true)

            var packageIsDir: ObjCBool = false
            let hasPackageSwift = fileManager.fileExists(atPath: packageSwift.path, isDirectory: &packageIsDir)
                && !packageIsDir.boolValue

            var fixturesIsDir: ObjCBool = false
            let hasFixturesDir = fileManager.fileExists(atPath: fixturesDir.path, isDirectory: &fixturesIsDir)
                && fixturesIsDir.boolValue

            if hasPackageSwift, hasFixturesDir {
                return candidate
            }

            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            if parent.path == candidate.path {
                throw Error.repoRootNotFound(startingAt: startingDirectory)
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
            options: []
        ) else {
            throw Error.failedToEnumerate(root)
        }

        var out: [String: URL] = [:]
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }

            // Explicitly ignore macOS metadata artifacts while continuing
            // to include other hidden files in the fixture mirror guard.
            let filename = fileURL.lastPathComponent
            guard filename != ".DS_Store", !filename.hasPrefix("._") else { continue }

            let relativePath = try makeRelativePath(fileURL: fileURL, root: root)
            out[relativePath] = fileURL
        }
        return out
    }

    static func filesAreEqual(_ lhs: URL, _ rhs: URL) throws -> Bool {
        // Small perf polish: if sizes differ, bytes differ.
        let keys: Set<URLResourceKey> = [.fileSizeKey]
        let lhsSize = try lhs.resourceValues(forKeys: keys).fileSize
        let rhsSize = try rhs.resourceValues(forKeys: keys).fileSize
        if let lhsSize, let rhsSize, lhsSize != rhsSize {
            return false
        }

        let lhsBytes = try Data(contentsOf: lhs)
        let rhsBytes = try Data(contentsOf: rhs)
        return lhsBytes == rhsBytes
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
