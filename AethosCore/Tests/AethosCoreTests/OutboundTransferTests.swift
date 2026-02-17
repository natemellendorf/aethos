import Foundation
import Testing
@testable import AethosCore

// MARK: - createOutboundTransfer creates transfer row

@Test
func createOutboundTransfer_createsTransferRow() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))

    // Create a test file
    let testFile = dir.appendingPathComponent("test.bin")
    let testData = Data(repeating: 0xAB, count: 1024)
    try testData.write(to: testFile)

    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let destinationId = "aabbccdd00112233"

    // Create outbound transfer
    let transferId = try OutboundTransfer.create(
        fileURL: testFile,
        destinationWayfarerId: destinationId,
        store: store,
        now: now
    )

    // Verify transfer was created
    let transfer = try store.getTransfer(id: transferId)
    #expect(transfer != nil)
    #expect(transfer?.transferId == transferId)
    #expect(transfer?.direction == .outbound)
    #expect(transfer?.peerTo == destinationId)
    #expect(transfer?.status == .queued)
    #expect(transfer?.custody == .origin)
    #expect(transfer?.originalFilename == "test.bin")
    #expect(transfer?.bytesTotal == 1024)
    #expect(transfer?.payloadHash != nil)
    #expect(transfer?.partsTotal == 0)  // Not yet sent
}

// MARK: - createOutboundTransfer rejects empty destination

@Test
func createOutboundTransfer_rejectsEmptyDestination() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))

    // Create a test file
    let testFile = dir.appendingPathComponent("test.bin")
    try Data(count: 100).write(to: testFile)

    // Empty destination should throw
    #expect(throws: CreateOutboundTransferError.destinationEmpty) {
        try OutboundTransfer.create(
            fileURL: testFile,
            destinationWayfarerId: "",
            store: store
        )
    }

    // Whitespace-only should also throw
    #expect(throws: CreateOutboundTransferError.destinationEmpty) {
        try OutboundTransfer.create(
            fileURL: testFile,
            destinationWayfarerId: "   ",
            store: store
        )
    }
}

// MARK: - createOutboundTransfer rejects missing file

@Test
func createOutboundTransfer_rejectsMissingFile() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))

    let nonexistentFile = dir.appendingPathComponent("does_not_exist.bin")

    #expect(throws: CreateOutboundTransferError.fileNotFound(nonexistentFile.path)) {
        try OutboundTransfer.create(
            fileURL: nonexistentFile,
            destinationWayfarerId: "aabbccdd",
            store: store
        )
    }
}

// MARK: - createOutboundTransfer stages outbox items

@Test
func createOutboundTransfer_stagesOutboxItems() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))

    // Create a test file
    let testFile = dir.appendingPathComponent("test.bin")
    let testData = Data(repeating: 0xCD, count: 512)
    try testData.write(to: testFile)

    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let destinationId = "aabbccdd00112233"

    // Create outbound transfer
    let transferId = try OutboundTransfer.create(
        fileURL: testFile,
        destinationWayfarerId: destinationId,
        store: store,
        now: now
    )

    // Verify transfer exists
    let transfer = try store.getTransfer(id: transferId)
    #expect(transfer != nil)

    // Verify outbox items were staged (manifest and envelope)
    let outboxItems = try store.peekQueuedOutbox(limit: 10)
    #expect(outboxItems.count >= 2)  // At least manifest + envelope

    let manifestItems = outboxItems.filter { $0.kind == .manifest }
    let envelopeItems = outboxItems.filter { $0.kind == .envelope }

    #expect(manifestItems.count == 1)
    #expect(envelopeItems.count == 1)
}

// MARK: - createOutboundTransfer handles invalid destination hex

@Test
func createOutboundTransfer_stillCreatesTransferWithInvalidHex() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))

    // Create a test file
    let testFile = dir.appendingPathComponent("test.bin")
    try Data(count: 100).write(to: testFile)

    // Invalid hex should still create transfer but skip outbox staging
    let transferId = try OutboundTransfer.create(
        fileURL: testFile,
        destinationWayfarerId: "invalid!hex@#",
        store: store
    )

    // Verify transfer was still created
    let transfer = try store.getTransfer(id: transferId)
    #expect(transfer != nil)
    #expect(transfer?.status == .queued)
}
