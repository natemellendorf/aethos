import Foundation
import Testing
@testable import AethosCore

/// Deterministic, in-memory duplex byte loopback for Gossip v1.
///
/// Purpose:
/// - Connect two `GossipV1StreamAdapter` instances with no sockets
/// - Pump length-prefixed stream bytes deterministically (no sleeps)
/// - Capture adapter events, application frames, and store effects
///
/// This is test-only support code.
final class GossipV1LoopbackHarness {
    final class Endpoint {
        private let outboundBox = LockedBox<[Data]>([])
        private let eventsBox = LockedBox<[GossipV1StreamAdapter.Event]>([])
        private let applicationFramesBox = LockedBox<[GossipV1Frame]>([])

        private var adapter: GossipV1StreamAdapter

        var state: GossipV1EncounterEngine.State { adapter.state }

        init(
            engine: GossipV1EncounterEngine,
            clock: some GossipV1EncounterEngine.Clock,
            store: some GossipV1EncounterEngine.Store,
            relayIngest: GossipV1StreamAdapter.RelayIngestConfig
        ) {
            let hooks = GossipV1StreamAdapter.Hooks(
                onSend: { [outboundBox] bytes in
                    outboundBox.withLock { $0.append(bytes) }
                },
                onEvent: { [eventsBox] event in
                    eventsBox.withLock { $0.append(event) }
                },
                onApplicationFrame: { [applicationFramesBox] frame in
                    applicationFramesBox.withLock { $0.append(frame) }
                }
            )

            self.adapter = GossipV1StreamAdapter(
                engine: engine,
                clock: clock,
                store: store,
                relayIngest: relayIngest,
                hooks: hooks
            )
        }

        var outbound: [Data] { outboundBox.withLock { $0 } }
        var events: [GossipV1StreamAdapter.Event] { eventsBox.withLock { $0 } }
        var applicationFrames: [GossipV1Frame] { applicationFramesBox.withLock { $0 } }

        func sendHello() {
            adapter.sendHello()
        }

        func sendFrame(_ frame: GossipV1Frame) {
            adapter.sendFrame(frame)
        }

        func receiveBytes(_ bytes: Data) {
            do {
                try adapter.receiveBytes(bytes)
            } catch {
                // Adapter only rethrows CancellationError; conformance tests never cancel.
                Issue.record("Unexpected receiveBytes error: \(error)")
            }
        }

        func finish() {
            do {
                try adapter.finish()
            } catch {
                Issue.record("Unexpected finish error: \(error)")
            }
        }

        fileprivate func popNextOutbound() -> Data? {
            outboundBox.withLock { outbound in
                guard !outbound.isEmpty else { return nil }
                return outbound.removeFirst()
            }
        }
    }

    struct PumpLimits: Sendable {
        var maxSteps: Int = 10_000
        var maxChunkBytes: Int = 17
    }

    let a: Endpoint
    let b: Endpoint

    private var aToBChunker: DeterministicChunker
    private var bToAChunker: DeterministicChunker

    init(a: Endpoint, b: Endpoint, seed: UInt64 = 1) {
        self.a = a
        self.b = b
        self.aToBChunker = DeterministicChunker(seed: seed ^ 0xA0A0)
        self.bToAChunker = DeterministicChunker(seed: seed ^ 0xB0B0)
    }

    /// Deterministically pumps bytes between endpoints until both are idle.
    func pumpUntilIdle(limits: PumpLimits = .init()) {
        var steps = 0
        while true {
            guard steps < limits.maxSteps else {
                Issue.record("pumpUntilIdle exceeded maxSteps=\(limits.maxSteps)")
                return
            }
            steps += 1

            if pumpOneDirection(from: a, to: b, chunker: &aToBChunker, maxChunkBytes: limits.maxChunkBytes) {
                continue
            }
            if pumpOneDirection(from: b, to: a, chunker: &bToAChunker, maxChunkBytes: limits.maxChunkBytes) {
                continue
            }

            // No bytes moved in either direction; idle.
            return
        }
    }

    @discardableResult
    private func pumpOneDirection(
        from: Endpoint,
        to: Endpoint,
        chunker: inout DeterministicChunker,
        maxChunkBytes: Int
    ) -> Bool {
        guard let streamFrameBytes = from.popNextOutbound() else { return false }

        for chunk in chunker.split(streamFrameBytes, maxChunkBytes: maxChunkBytes) {
            to.receiveBytes(chunk)
        }
        return true
    }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) {
        self.value = value
    }

    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

// MARK: - Deterministic chunking

private struct DeterministicChunker {
    // Xorshift64* PRNG; deterministic and tiny.
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0xDEADBEEF : seed
    }

    mutating func split(_ bytes: Data, maxChunkBytes: Int) -> [Data] {
        guard !bytes.isEmpty else { return [] }
        guard maxChunkBytes > 0 else { return [bytes] }

        var chunks: [Data] = []
        chunks.reserveCapacity((bytes.count / maxChunkBytes) + 1)

        var i = 0
        while i < bytes.count {
            let remaining = bytes.count - i
            let next = min(remaining, nextChunkSize(upperBound: maxChunkBytes))
            chunks.append(bytes.subdata(in: i..<(i + next)))
            i += next
        }
        return chunks
    }

    private mutating func nextChunkSize(upperBound: Int) -> Int {
        precondition(upperBound > 0)
        // Advance PRNG.
        state ^= (state >> 12)
        state ^= (state << 25)
        state ^= (state >> 27)
        let x = state &* 0x2545F4914F6CDD1D

        // Map into [1, upperBound].
        return Int((x % UInt64(upperBound)) + 1)
    }
}

// MARK: - Test support

struct GossipV1FixedClock: GossipV1EncounterEngine.Clock {
    let nowMs: UInt64
    func nowUnixMs() -> UInt64 { nowMs }
}

/// In-memory store with deterministic behavior and observability.
final class GossipV1InMemoryStore: @unchecked Sendable, GossipV1EncounterEngine.Store {
    struct Entry: Sendable {
        var envelopeBytes: Data
        var expiryUnixMs: UInt64
        var hopCount: UInt16
    }

    private var storedByID: [GossipV1ItemID: Entry] = [:]
    private var eligible: [GossipV1ItemID] = []

    private(set) var ingestCallsByID: [GossipV1ItemID: Int] = [:]
    private(set) var firstTimeIngested: Set<GossipV1ItemID> = []

    func eligibleItemIDs(nowMs _: UInt64) throws -> [GossipV1ItemID] { eligible }

    func fetch(_ itemID: GossipV1ItemID) throws -> (envelopeBytes: Data, expiryUnixMs: UInt64, hopCount: UInt16)? {
        guard let e = storedByID[itemID] else { return nil }
        return (e.envelopeBytes, e.expiryUnixMs, e.hopCount)
    }

    func existingHopCount(_ itemID: GossipV1ItemID) throws -> UInt16? {
        storedByID[itemID]?.hopCount
    }

    func ingest(_ itemID: GossipV1ItemID, envelopeBytes: Data, expiryUnixMs: UInt64, hopCount: UInt16) throws {
        ingestCallsByID[itemID, default: 0] += 1

        if let existing = storedByID[itemID], hopCount < existing.hopCount {
            throw GossipV1EncounterEngine.ValidationError.hopRegression(existing: existing.hopCount, incoming: hopCount)
        }

        if storedByID[itemID] == nil {
            firstTimeIngested.insert(itemID)
        }

        storedByID[itemID] = Entry(envelopeBytes: envelopeBytes, expiryUnixMs: expiryUnixMs, hopCount: hopCount)
    }

    func put(itemID: GossipV1ItemID, envelopeBytes: Data, expiryUnixMs: UInt64, hopCount: UInt16) {
        storedByID[itemID] = Entry(envelopeBytes: envelopeBytes, expiryUnixMs: expiryUnixMs, hopCount: hopCount)
    }

    func entry(_ itemID: GossipV1ItemID) -> Entry? {
        storedByID[itemID]
    }

    func setEligible(_ ids: [GossipV1ItemID]) {
        eligible = ids
    }
}

final class GossipV1InMemoryRelayObserver: @unchecked Sendable, GossipV1EncounterEngine.RelayIngestObserving {
    private(set) var attemptCount: Int = 0
    private(set) var calls: [(itemIDs: [GossipV1ItemID], nowMs: UInt64)] = []
    var errorToThrow: (any Swift.Error)?

    func noteAuthenticatedRelayIngest(itemIDs: [GossipV1ItemID], nowMs: UInt64) throws {
        attemptCount += 1
        if let errorToThrow { throw errorToThrow }
        calls.append((itemIDs: itemIDs, nowMs: nowMs))
    }
}

func gossipV1_makeHello(pubKeyByte: UInt8, version: UInt64 = GossipV1.GOSSIP_VERSION, maxWant: UInt64 = 128, maxTransfer: UInt64 = 16) throws -> GossipV1HelloFrame {
    let pubKey = Data(repeating: pubKeyByte, count: 32)
    let nodeID = GossipV1NodeID.derive(fromPublicKeyRawBytes: pubKey)
    return try GossipV1HelloFrame(
        version: version,
        nodeID: nodeID,
        nodePublicKeyRawBytes: pubKey,
        capabilities: ["store"],
        propagationClass: "direct",
        maxWant: maxWant,
        maxTransfer: maxTransfer
    )
}
