import Foundation

public enum GossipV1Bearer: Hashable, Sendable {
    case relay(String)
    case lan(interface: String)
}

public struct GossipV1InventoryDelta: Equatable, Sendable {
    public let added: [String]
    public let removed: [String]

    public var isNoOp: Bool {
        added.isEmpty && removed.isEmpty
    }

    public init(added: [String], removed: [String]) {
        self.added = added
        self.removed = removed
    }
}

public enum GossipV1AdvertisementPlan: Equatable, Sendable {
    case full([String])
    case delta(GossipV1InventoryDelta)
    case suppressNoOp
}

public enum GossipV1RequestPlan: Equatable, Sendable {
    case send([GossipV1ItemID])
    case suppressEmpty
    case suppressNoOp
}

public enum GossipV1LanDiscoveryAction: Equatable, Sendable {
    case multicastProbe(interface: String)
    case unicastFollowUp(interface: String, peerID: String, endpoint: String)
}

public struct GossipV1ChatterMetrics: Equatable, Sendable {
    public private(set) var advertisementFullPlanned: Int = 0
    public private(set) var advertisementDeltaPlanned: Int = 0
    public private(set) var advertisementNoOpSuppressed: Int = 0

    public private(set) var requestPlanned: Int = 0
    public private(set) var requestEmptySuppressed: Int = 0
    public private(set) var requestNoOpSuppressed: Int = 0

    public private(set) var lanMulticastPlanned: Int = 0
    public private(set) var lanMulticastSuppressedByInterface: Int = 0
    public private(set) var lanUnicastFollowUpEnqueued: Int = 0

    public private(set) var crossBearerDedupeSuppressed: Int = 0

    public init() {}

    mutating func noteAdvertisementFullPlanned() { advertisementFullPlanned += 1 }
    mutating func noteAdvertisementDeltaPlanned() { advertisementDeltaPlanned += 1 }
    mutating func noteAdvertisementNoOpSuppressed() { advertisementNoOpSuppressed += 1 }

    mutating func noteRequestPlanned() { requestPlanned += 1 }
    mutating func noteRequestEmptySuppressed() { requestEmptySuppressed += 1 }
    mutating func noteRequestNoOpSuppressed() { requestNoOpSuppressed += 1 }

    mutating func noteLanMulticastPlanned(count: Int) { lanMulticastPlanned += count }
    mutating func noteLanMulticastSuppressed(count: Int) { lanMulticastSuppressedByInterface += count }
    mutating func noteLanUnicastFollowUpEnqueued(count: Int) { lanUnicastFollowUpEnqueued += count }

    mutating func noteCrossBearerDedupeSuppressed() { crossBearerDedupeSuppressed += 1 }
}

public struct GossipV1AdaptivePacer: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case deltaPlanned
        case noOpSuppressed
        case transientFailure
    }

    public struct Config: Equatable, Sendable {
        public enum ValidationError: Error, Equatable, Sendable {
            case minIntervalNegative(actual: Int)
            case maxIntervalLessThanMin(min: Int, max: Int)
            case initialIntervalOutOfRange(min: Int, max: Int, actual: Int)
            case noOpBackoffMultiplierLessThanOne(actual: Double)
            case failureBackoffMultiplierLessThanOne(actual: Double)
            case noOpBackoffMultiplierNonFinite(actual: Double)
            case failureBackoffMultiplierNonFinite(actual: Double)
            case jitterNegative(actual: Int)
        }

        public let minIntervalMs: Int
        public let maxIntervalMs: Int
        public let initialIntervalMs: Int
        public let noOpBackoffMultiplier: Double
        public let failureBackoffMultiplier: Double
        public let jitterMs: Int

        public static let `default` = Config(
            minIntervalMs: 500,
            maxIntervalMs: 30_000,
            initialIntervalMs: 2_000,
            noOpBackoffMultiplier: 1.5,
            failureBackoffMultiplier: 2.0,
            jitterMs: 200
        )

        public init(
            minIntervalMs: Int,
            maxIntervalMs: Int,
            initialIntervalMs: Int,
            noOpBackoffMultiplier: Double,
            failureBackoffMultiplier: Double,
            jitterMs: Int
        ) {
            precondition(minIntervalMs >= 0, "GossipV1AdaptivePacer.Config minIntervalMs must be >= 0")
            precondition(maxIntervalMs >= minIntervalMs, "GossipV1AdaptivePacer.Config maxIntervalMs must be >= minIntervalMs")
            precondition(
                (minIntervalMs ... maxIntervalMs).contains(initialIntervalMs),
                "GossipV1AdaptivePacer.Config initialIntervalMs must be in minIntervalMs...maxIntervalMs"
            )
            precondition(noOpBackoffMultiplier.isFinite, "GossipV1AdaptivePacer.Config noOpBackoffMultiplier must be finite")
            precondition(failureBackoffMultiplier.isFinite, "GossipV1AdaptivePacer.Config failureBackoffMultiplier must be finite")
            precondition(
                noOpBackoffMultiplier >= 1.0,
                "GossipV1AdaptivePacer.Config noOpBackoffMultiplier must be >= 1.0"
            )
            precondition(
                failureBackoffMultiplier >= 1.0,
                "GossipV1AdaptivePacer.Config failureBackoffMultiplier must be >= 1.0"
            )
            precondition(jitterMs >= 0, "GossipV1AdaptivePacer.Config jitterMs must be >= 0")

            self.minIntervalMs = minIntervalMs
            self.maxIntervalMs = maxIntervalMs
            self.initialIntervalMs = initialIntervalMs
            self.noOpBackoffMultiplier = noOpBackoffMultiplier
            self.failureBackoffMultiplier = failureBackoffMultiplier
            self.jitterMs = jitterMs
        }

        public init(
            validating minIntervalMs: Int,
            maxIntervalMs: Int,
            initialIntervalMs: Int,
            noOpBackoffMultiplier: Double,
            failureBackoffMultiplier: Double,
            jitterMs: Int
        ) throws {
            if minIntervalMs < 0 {
                throw ValidationError.minIntervalNegative(actual: minIntervalMs)
            }

            if maxIntervalMs < minIntervalMs {
                throw ValidationError.maxIntervalLessThanMin(min: minIntervalMs, max: maxIntervalMs)
            }

            if !(minIntervalMs ... maxIntervalMs).contains(initialIntervalMs) {
                throw ValidationError.initialIntervalOutOfRange(
                    min: minIntervalMs,
                    max: maxIntervalMs,
                    actual: initialIntervalMs
                )
            }

            if !noOpBackoffMultiplier.isFinite {
                throw ValidationError.noOpBackoffMultiplierNonFinite(actual: noOpBackoffMultiplier)
            }

            if !failureBackoffMultiplier.isFinite {
                throw ValidationError.failureBackoffMultiplierNonFinite(actual: failureBackoffMultiplier)
            }

            if noOpBackoffMultiplier < 1.0 {
                throw ValidationError.noOpBackoffMultiplierLessThanOne(actual: noOpBackoffMultiplier)
            }

            if failureBackoffMultiplier < 1.0 {
                throw ValidationError.failureBackoffMultiplierLessThanOne(actual: failureBackoffMultiplier)
            }

            if jitterMs < 0 {
                throw ValidationError.jitterNegative(actual: jitterMs)
            }

            self.minIntervalMs = minIntervalMs
            self.maxIntervalMs = maxIntervalMs
            self.initialIntervalMs = initialIntervalMs
            self.noOpBackoffMultiplier = noOpBackoffMultiplier
            self.failureBackoffMultiplier = failureBackoffMultiplier
            self.jitterMs = jitterMs
        }
    }

    public let config: Config
    public private(set) var currentIntervalMs: Int

    public init(config: Config = .default) {
        self.config = config
        self.currentIntervalMs = Self.clamp(
            config.initialIntervalMs,
            min: config.minIntervalMs,
            max: config.maxIntervalMs
        )
    }

    public mutating func register(outcome: Outcome) {
        switch outcome {
        case .deltaPlanned:
            currentIntervalMs = Self.clamp(
                max(config.minIntervalMs, currentIntervalMs / 2),
                min: config.minIntervalMs,
                max: config.maxIntervalMs
            )
        case .noOpSuppressed:
            currentIntervalMs = Self.clamp(
                Int(Double(currentIntervalMs) * config.noOpBackoffMultiplier),
                min: config.minIntervalMs,
                max: config.maxIntervalMs
            )
        case .transientFailure:
            currentIntervalMs = Self.clamp(
                Int(Double(currentIntervalMs) * config.failureBackoffMultiplier),
                min: config.minIntervalMs,
                max: config.maxIntervalMs
            )
        }
    }

    public func nextDelayMs(jitterSample: Double) -> Int {
        let clampedSample = max(0.0, min(1.0, jitterSample))
        let offsetRange = config.jitterMs * 2
        let offset = Int((Double(offsetRange) * clampedSample).rounded(.down)) - config.jitterMs
        return Self.clamp(currentIntervalMs + offset, min: config.minIntervalMs, max: config.maxIntervalMs)
    }

    private static func clamp(_ value: Int, min: Int, max: Int) -> Int {
        Swift.max(min, Swift.min(max, value))
    }
}

public struct GossipV1CrossBearerDeduplicator: Sendable {
    public struct Config: Equatable, Sendable {
        public let suppressionWindowMs: UInt64

        public static let `default` = Config(suppressionWindowMs: 5_000)

        public init(suppressionWindowMs: UInt64) {
            self.suppressionWindowMs = suppressionWindowMs
        }
    }

    private struct SeenRecord: Sendable {
        var lastTransmittedAtMs: UInt64
        var bearers: Set<GossipV1Bearer>
    }

    public let config: Config
    private var seenByFingerprint: [Data: SeenRecord]

    public init(config: Config = .default) {
        self.config = config
        self.seenByFingerprint = [:]
    }

    public mutating func shouldTransmit(fingerprint: Data, via bearer: GossipV1Bearer, nowMs: UInt64) -> Bool {
        evictExpired(nowMs: nowMs)

        guard let existing = seenByFingerprint[fingerprint] else {
            return true
        }

        guard nowMs >= existing.lastTransmittedAtMs else {
            return existing.bearers.contains(bearer)
        }

        let elapsed = nowMs - existing.lastTransmittedAtMs
        guard elapsed < config.suppressionWindowMs else { return true }
        return existing.bearers.contains(bearer)
    }

    public mutating func noteDidTransmit(fingerprint: Data, via bearer: GossipV1Bearer, nowMs: UInt64) {
        evictExpired(nowMs: nowMs)

        guard var existing = seenByFingerprint[fingerprint] else {
            seenByFingerprint[fingerprint] = SeenRecord(lastTransmittedAtMs: nowMs, bearers: [bearer])
            return
        }

        if nowMs >= existing.lastTransmittedAtMs {
            existing.lastTransmittedAtMs = nowMs
        }
        existing.bearers.insert(bearer)
        seenByFingerprint[fingerprint] = existing
    }

    private mutating func evictExpired(nowMs: UInt64) {
        guard config.suppressionWindowMs > 0 else {
            seenByFingerprint.removeAll(keepingCapacity: true)
            return
        }

        var expired: [Data] = []
        expired.reserveCapacity(seenByFingerprint.count)
        for (fingerprint, record) in seenByFingerprint {
            guard nowMs >= record.lastTransmittedAtMs else { continue }
            if nowMs - record.lastTransmittedAtMs > config.suppressionWindowMs {
                expired.append(fingerprint)
            }
        }

        for fingerprint in expired {
            seenByFingerprint.removeValue(forKey: fingerprint)
        }
    }
}

public struct GossipV1LanDiscoveryPlanner: Sendable {
    public struct Config: Equatable, Sendable {
        public let followUpDelayMs: UInt64
        public let interfaceSuppressionWindowMs: UInt64
        public let maxResponseAgeMs: UInt64
        public let maxUnicastFollowUpsPerTick: Int

        public static let `default` = Config(
            followUpDelayMs: 250,
            interfaceSuppressionWindowMs: 1_000,
            maxResponseAgeMs: 2_000,
            maxUnicastFollowUpsPerTick: 8
        )

        public init(
            followUpDelayMs: UInt64,
            interfaceSuppressionWindowMs: UInt64,
            maxResponseAgeMs: UInt64,
            maxUnicastFollowUpsPerTick: Int
        ) {
            self.followUpDelayMs = followUpDelayMs
            self.interfaceSuppressionWindowMs = interfaceSuppressionWindowMs
            self.maxResponseAgeMs = maxResponseAgeMs
            self.maxUnicastFollowUpsPerTick = maxUnicastFollowUpsPerTick
        }
    }

    public struct MulticastBatch: Equatable, Sendable {
        public let actions: [GossipV1LanDiscoveryAction]
        public let suppressedInterfaces: [String]

        public init(actions: [GossipV1LanDiscoveryAction], suppressedInterfaces: [String]) {
            self.actions = actions
            self.suppressedInterfaces = suppressedInterfaces
        }
    }

    private struct FollowUpKey: Hashable, Sendable {
        let interface: String
        let peerID: String
    }

    private struct PendingFollowUp: Sendable {
        let key: FollowUpKey
        let endpoint: String
        let dueAtMs: UInt64
    }

    public let config: Config
    private var lastMulticastAtByInterface: [String: UInt64]
    private var pendingByKey: [FollowUpKey: PendingFollowUp]

    public init(config: Config = .default) {
        self.config = config
        self.lastMulticastAtByInterface = [:]
        self.pendingByKey = [:]
    }

    public mutating func beginRound(nowMs: UInt64, interfaces: [String]) -> MulticastBatch {
        let normalizedInterfaces = Array(Set(interfaces.filter { !$0.isEmpty })).sorted()
        guard !normalizedInterfaces.isEmpty else {
            return MulticastBatch(actions: [], suppressedInterfaces: [])
        }

        var actions: [GossipV1LanDiscoveryAction] = []
        var suppressed: [String] = []

        for interface in normalizedInterfaces {
            if shouldSuppressMulticast(interface: interface, nowMs: nowMs) {
                suppressed.append(interface)
                continue
            }

            lastMulticastAtByInterface[interface] = nowMs
            actions.append(.multicastProbe(interface: interface))
        }

        return MulticastBatch(actions: actions, suppressedInterfaces: suppressed)
    }

    public mutating func recordMulticastResponse(
        interface: String,
        peerID: String,
        endpoint: String,
        nowMs: UInt64
    ) {
        guard !interface.isEmpty, !peerID.isEmpty, !endpoint.isEmpty else { return }
        guard let lastMulticastAt = lastMulticastAtByInterface[interface], nowMs >= lastMulticastAt else { return }

        let responseAgeMs = nowMs - lastMulticastAt
        guard responseAgeMs <= config.maxResponseAgeMs else { return }

        let key = FollowUpKey(interface: interface, peerID: peerID)
        pendingByKey[key] = PendingFollowUp(
            key: key,
            endpoint: endpoint,
            dueAtMs: nowMs + config.followUpDelayMs
        )
    }

    public mutating func dueFollowUps(nowMs: UInt64) -> [GossipV1LanDiscoveryAction] {
        let due = pendingByKey.values
            .filter { $0.dueAtMs <= nowMs }
            .sorted { lhs, rhs in
                if lhs.dueAtMs != rhs.dueAtMs {
                    return lhs.dueAtMs < rhs.dueAtMs
                }
                if lhs.key.interface != rhs.key.interface {
                    return lhs.key.interface < rhs.key.interface
                }
                return lhs.key.peerID < rhs.key.peerID
            }

        guard !due.isEmpty else { return [] }

        let allowed = max(0, config.maxUnicastFollowUpsPerTick)
        let selected = due.prefix(allowed)
        for followUp in selected {
            pendingByKey.removeValue(forKey: followUp.key)
        }

        return selected.map {
            .unicastFollowUp(interface: $0.key.interface, peerID: $0.key.peerID, endpoint: $0.endpoint)
        }
    }

    private func shouldSuppressMulticast(interface: String, nowMs: UInt64) -> Bool {
        guard let lastMulticastAt = lastMulticastAtByInterface[interface] else { return false }
        guard nowMs >= lastMulticastAt else { return false }
        return nowMs - lastMulticastAt < config.interfaceSuppressionWindowMs
    }
}

public struct GossipV1ChatterCoordinator: Sendable {
    public struct Config: Equatable, Sendable {
        public let pacer: GossipV1AdaptivePacer.Config
        public let dedupe: GossipV1CrossBearerDeduplicator.Config
        public let discovery: GossipV1LanDiscoveryPlanner.Config

        public static let `default` = Config(
            pacer: .default,
            dedupe: .default,
            discovery: .default
        )

        public init(
            pacer: GossipV1AdaptivePacer.Config,
            dedupe: GossipV1CrossBearerDeduplicator.Config,
            discovery: GossipV1LanDiscoveryPlanner.Config
        ) {
            self.pacer = pacer
            self.dedupe = dedupe
            self.discovery = discovery
        }
    }

    public private(set) var metrics: GossipV1ChatterMetrics
    public private(set) var pacer: GossipV1AdaptivePacer

    private var lastAdvertisedManifestSetByBearer: [GossipV1Bearer: Set<String>]
    private var lastRequestByBearer: [GossipV1Bearer: [GossipV1ItemID]]
    private var deduplicator: GossipV1CrossBearerDeduplicator
    private var discoveryPlanner: GossipV1LanDiscoveryPlanner

    public init(config: Config = .default) {
        metrics = GossipV1ChatterMetrics()
        pacer = GossipV1AdaptivePacer(config: config.pacer)
        lastAdvertisedManifestSetByBearer = [:]
        lastRequestByBearer = [:]
        deduplicator = GossipV1CrossBearerDeduplicator(config: config.dedupe)
        discoveryPlanner = GossipV1LanDiscoveryPlanner(config: config.discovery)
    }

    public mutating func planAdvertisement(
        for bearer: GossipV1Bearer,
        manifests: [String]
    ) -> GossipV1AdvertisementPlan {
        let normalizedSet = Set(manifests.filter { !$0.isEmpty })
        let normalizedSorted = normalizedSet.sorted()

        guard let previous = lastAdvertisedManifestSetByBearer[bearer] else {
            lastAdvertisedManifestSetByBearer[bearer] = normalizedSet
            metrics.noteAdvertisementFullPlanned()
            pacer.register(outcome: .deltaPlanned)
            return .full(normalizedSorted)
        }

        let delta = Self.inventoryDelta(previous: previous, current: normalizedSet)
        guard !delta.isNoOp else {
            metrics.noteAdvertisementNoOpSuppressed()
            pacer.register(outcome: .noOpSuppressed)
            return .suppressNoOp
        }

        lastAdvertisedManifestSetByBearer[bearer] = normalizedSet
        metrics.noteAdvertisementDeltaPlanned()
        pacer.register(outcome: .deltaPlanned)
        return .delta(delta)
    }

    public mutating func planRequest(
        for bearer: GossipV1Bearer,
        want: [GossipV1ItemID]
    ) -> GossipV1RequestPlan {
        let normalizedWant = Self.normalizeWant(want)

        guard !normalizedWant.isEmpty else {
            metrics.noteRequestEmptySuppressed()
            pacer.register(outcome: .noOpSuppressed)
            return .suppressEmpty
        }

        if let previous = lastRequestByBearer[bearer], previous == normalizedWant {
            metrics.noteRequestNoOpSuppressed()
            pacer.register(outcome: .noOpSuppressed)
            return .suppressNoOp
        }

        lastRequestByBearer[bearer] = normalizedWant
        metrics.noteRequestPlanned()
        pacer.register(outcome: .deltaPlanned)
        return .send(normalizedWant)
    }

    public mutating func shouldTransmit(
        fingerprint: Data,
        via bearer: GossipV1Bearer,
        nowMs: UInt64
    ) -> Bool {
        let shouldTransmit = deduplicator.shouldTransmit(fingerprint: fingerprint, via: bearer, nowMs: nowMs)
        if !shouldTransmit {
            metrics.noteCrossBearerDedupeSuppressed()
        }
        return shouldTransmit
    }

    public mutating func noteDidTransmit(
        fingerprint: Data,
        via bearer: GossipV1Bearer,
        nowMs: UInt64
    ) {
        deduplicator.noteDidTransmit(fingerprint: fingerprint, via: bearer, nowMs: nowMs)
    }

    public mutating func beginLanDiscovery(nowMs: UInt64, interfaces: [String]) -> [GossipV1LanDiscoveryAction] {
        let batch = discoveryPlanner.beginRound(nowMs: nowMs, interfaces: interfaces)
        metrics.noteLanMulticastPlanned(count: batch.actions.count)
        metrics.noteLanMulticastSuppressed(count: batch.suppressedInterfaces.count)
        return batch.actions
    }

    public mutating func noteLanDiscoveryResponse(
        interface: String,
        peerID: String,
        endpoint: String,
        nowMs: UInt64
    ) {
        discoveryPlanner.recordMulticastResponse(
            interface: interface,
            peerID: peerID,
            endpoint: endpoint,
            nowMs: nowMs
        )
    }

    public mutating func dueLanFollowUps(nowMs: UInt64) -> [GossipV1LanDiscoveryAction] {
        let actions = discoveryPlanner.dueFollowUps(nowMs: nowMs)
        metrics.noteLanUnicastFollowUpEnqueued(count: actions.count)
        return actions
    }

    public mutating func notePacingFailure() {
        pacer.register(outcome: .transientFailure)
    }

    public func nextRecommendedDelayMs(jitterSample: Double) -> Int {
        pacer.nextDelayMs(jitterSample: jitterSample)
    }

    public static func inventoryDelta(previous: Set<String>, current: Set<String>) -> GossipV1InventoryDelta {
        let added = current.subtracting(previous).sorted()
        let removed = previous.subtracting(current).sorted()
        return GossipV1InventoryDelta(added: added, removed: removed)
    }

    private static func normalizeWant(_ want: [GossipV1ItemID]) -> [GossipV1ItemID] {
        Array(Set(want)).sorted {
            DataLexicographic.compare($0.rawBytes(), $1.rawBytes()) == .orderedAscending
        }
    }
}
