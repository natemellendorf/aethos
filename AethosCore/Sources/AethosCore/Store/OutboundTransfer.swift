import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Errors that can occur when creating an outbound transfer.
public enum CreateOutboundTransferError: Swift.Error, Equatable {
    case destinationEmpty
    case fileNotFound(String)
    case fileNotReadable(String)
}

/// Public API for creating outbound transfers from files.
///
/// This API enables iOS/CoreBridge to create real outbound transfers in-process,
/// handling file validation, transfer creation, and outbox staging.
public struct OutboundTransfer {
    /// Creates an outbound transfer from a local file to a destination peer.
    ///
    /// - Parameters:
    ///   - fileURL: URL of the file to transfer.
    ///   - destinationWayfarerId: Wayfarer ID of the destination peer (hex string).
    ///   - store: The AethosStore to persist the transfer.
    ///   - now: Current timestamp (defaults to Date()).
    /// - Returns: The transfer ID of the created outbound transfer.
    /// - Throws: `CreateOutboundTransferError` if validation fails.
    public static func create(
        fileURL: URL,
        destinationWayfarerId: String,
        store: AethosStore,
        now: Date = Date()
    ) throws -> String {
        // Guard: validate destination is non-empty after trimming
        let trimmedDestination = destinationWayfarerId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDestination.isEmpty else {
            throw CreateOutboundTransferError.destinationEmpty
        }

        // Guard: validate file exists
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw CreateOutboundTransferError.fileNotFound(fileURL.path)
        }

        // Guard: validate file is readable
        guard fileManager.isReadableFile(atPath: fileURL.path) else {
            throw CreateOutboundTransferError.fileNotReadable(fileURL.path)
        }

        // Read file contents to compute size and hash
        let fileData: Data
        do {
            fileData = try Data(contentsOf: fileURL)
        } catch {
            throw CreateOutboundTransferError.fileNotReadable(fileURL.path)
        }

        // Compute file size
        let fileSize = Int64(fileData.count)

        // Compute payload hash
        let payloadHash = AethosIDs.sha256(fileData).hexString

        // Extract filename from URL
        let filename = fileURL.lastPathComponent

        // Generate transfer ID
        let transferId = Transfer.newId()

        // Create the transfer with queued status and origin custody
        let transfer = Transfer(
            transferId: transferId,
            direction: .outbound,
            peerFrom: "",  // Empty for origin - we are the sender
            peerTo: trimmedDestination,
            createdAt: now,
            updatedAt: now,
            lastActivityAt: now,
            status: .queued,
            originalFilename: filename,
            bytesTotal: fileSize,
            bytesSent: 0,
            bytesReceived: 0,
            partsTotal: 0,
            partsSent: 0,
            partsReceived: 0,
            manifestHash: nil,
            payloadHash: payloadHash,
            verified: false,
            lastError: nil,
            custody: .origin  // We are the origin of this transfer
        )

        // Persist the transfer
        try store.createTransfer(transfer)

        // Stage outbox items for the sync loop:
        // 1. Chunk the file and store chunks
        // 2. Build manifest
        // 3. Enqueue manifest
        // 4. Enqueue envelope
        let chunks = Chunking.chunk(fileData)
        for chunk in chunks {
            try store.putChunk(id: chunk.id, bytes: chunk.bytes, receivedAt: now)
        }

        let manifest = Chunking.buildManifest(for: fileData)
        let manifestBytes = CanonicalEncoderV1.encode(manifest)
        let manifestId = AethosIDs.manifestId(from: manifest)

        // Convert destination to Data for envelope
        guard let destinationData = Hex.decode(trimmedDestination) else {
            // If hex decode fails, we still created the transfer but can't stage outbox
            // This is acceptable - the transfer exists and can be updated later
            return transferId
        }

        let envelope = EnvelopeV1(
            toWayfarerId: destinationData,
            manifestId: manifestId,
            body: Data(filename.utf8)
        )
        let envelopeBytes = CanonicalEncoderV1.encode(envelope)
        let envelopeId = AethosIDs.envelopeId(from: envelope)

        // Enqueue manifest and envelope for sync loop
        try store.enqueue(item: OutboxItem(
            id: manifestId,
            kind: .manifest,
            payload: manifestBytes,
            enqueuedAt: now
        ))
        try store.enqueue(item: OutboxItem(
            id: envelopeId,
            kind: .envelope,
            payload: envelopeBytes,
            enqueuedAt: now
        ))

        return transferId
    }
}
