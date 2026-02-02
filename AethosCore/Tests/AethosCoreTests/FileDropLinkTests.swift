import Foundation
import Testing
@testable import AethosCore

@Test
func fileDropEmptyInboxReturnsNil() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let link = try FileDropLink(
        inboxDir: root.appendingPathComponent("inbox", isDirectory: true),
        outboxDir: root.appendingPathComponent("outbox", isDirectory: true),
        archiveDir: root.appendingPathComponent("archive", isDirectory: true)
    )

    let frame = try link.receive()
    #expect(frame == nil)
}

@Test
func fileDropRoundTripAndArchive() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    try fm.createDirectory(at: root, withIntermediateDirectories: true)

    let inbox = root.appendingPathComponent("inbox", isDirectory: true)
    let outbox = root.appendingPathComponent("outbox", isDirectory: true)
    let archive = root.appendingPathComponent("archive", isDirectory: true)

    let link = try FileDropLink(inboxDir: inbox, outboxDir: outbox, archiveDir: archive)

    let payload = Data((0..<2048).map { UInt8($0 % 251) })
    let frame = Frame(type: CargoCodec.FrameType.manifest.rawValue, id: AethosIDs.sha256(payload), partIndex: 0, partCount: 1, payload: payload)
    try link.send(frame)

    let outFiles = try fm.contentsOfDirectory(at: outbox, includingPropertiesForKeys: nil)
    #expect(outFiles.count == 1)
    let outFile = outFiles[0]

    // Simulate transport: move outbox -> inbox.
    let inboxFile = inbox.appendingPathComponent(outFile.lastPathComponent, isDirectory: false)
    try fm.moveItem(at: outFile, to: inboxFile)

    let received = try link.receive()
    #expect(received == frame)

    // File should be in archive now.
    let archived = try fm.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil)
    #expect(archived.count == 1)
    #expect(archived[0].lastPathComponent == inboxFile.lastPathComponent)
    #expect((try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil).count) == 0)
}

@Test
func fileDropUnreadableInboxEntryIsArchivedAsBadAndSkipped() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    try fm.createDirectory(at: root, withIntermediateDirectories: true)

    let inbox = root.appendingPathComponent("inbox", isDirectory: true)
    let outbox = root.appendingPathComponent("outbox", isDirectory: true)
    let archive = root.appendingPathComponent("archive", isDirectory: true)
    _ = try FileDropLink(inboxDir: inbox, outboxDir: outbox, archiveDir: archive)

    // Create a directory inside inbox to force Data(contentsOf:) to fail.
    let bad = inbox.appendingPathComponent("000-bad", isDirectory: true)
    try fm.createDirectory(at: bad, withIntermediateDirectories: false)

    // Also add a good frame file after it; receive() should skip bad and return good.
    let payload = Data("ok".utf8)
    let goodFrame = Frame(type: CargoCodec.FrameType.receipt.rawValue, id: AethosIDs.sha256(payload), partIndex: 0, partCount: 1, payload: payload)
    let goodBytes = goodFrame.encode()
    let goodFile = inbox.appendingPathComponent("001-good.bin", isDirectory: false)
    try goodBytes.write(to: goodFile, options: [.atomic])

    let link = try FileDropLink(inboxDir: inbox, outboxDir: outbox, archiveDir: archive)
    let received = try link.receive()
    #expect(received == goodFrame)

    let archived = try fm.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil)
    #expect(archived.contains { $0.lastPathComponent.hasPrefix("000-bad") && $0.lastPathComponent.hasSuffix(".bad") })
    #expect(archived.contains { $0.lastPathComponent == "001-good.bin" })
}
