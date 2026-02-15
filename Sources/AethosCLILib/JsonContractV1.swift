import AethosCore
import Foundation

public enum CLIContractV1 {
    public static let contractName = "aethos.cli.json.v1"
    public static let contractVersion = 1

    public static func base(command: String) -> [String: Any] {
        [
            "contract": [
                "name": contractName,
                "version": contractVersion,
            ],
            "command": command,
            "ok": true,
        ]
    }

    public static func error(command: String?, type: String, message: String) -> [String: Any] {
        let out: [String: Any] = [
            "contract": [
                "name": contractName,
                "version": contractVersion,
            ],
            "command": command ?? "",
            "ok": false,
            "error": [
                "type": type,
                "message": message,
            ],
        ]
        return out
    }

    public static func status(storeExists: Bool, identity: IdentityV1?) -> [String: Any] {
        var out = base(command: "status")
        out["store"] = [
            "exists": storeExists,
        ] as [String: Any]
        out["identity"] = identityDict(identity)
        out["transfers_summary"] = [
            "total": 0,
            "queued": 0,
            "sending": 0,
            "receiving": 0,
            "complete": 0,
            "failed": 0,
            "evicted": 0,
        ] as [String: Any]
        out["peers_summary"] = [
            "total": 0,
            "stale": 0,
            "recently_seen": 0,
        ] as [String: Any]
        return out
    }

    public static func status(
        storeExists: Bool,
        identity: IdentityV1?,
        transfersSummary: [String: Any],
        peersSummary: [String: Any]
    ) -> [String: Any] {
        var out = base(command: "status")
        out["store"] = [
            "exists": storeExists,
        ] as [String: Any]
        out["identity"] = identityDict(identity)
        out["transfers_summary"] = transfersSummary
        out["peers_summary"] = peersSummary
        return out
    }

    public static func transfersList(_ transfers: [Transfer]) -> [String: Any] {
        var out = base(command: "transfers.list")
        let sorted = transfers.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.transferId < $1.transferId
        }
        out["transfers"] = sorted.map { transferDict($0) }
        out["count"] = sorted.count
        return out
    }

    public static func transfersShow(_ transfer: Transfer) -> [String: Any] {
        var out = base(command: "transfers.show")
        out["transfer"] = transferDict(transfer)
        return out
    }

    public static func peersList(
        peers: [Peer],
        summaryTotal: Int,
        summaryStale: Int,
        nowEpochSeconds: Int64,
        staleAfterSeconds: Int64
    ) -> [String: Any] {
        var out = base(command: "peers.list")
        let sorted = peers.sorted {
            if $0.lastSeenAt != $1.lastSeenAt { return $0.lastSeenAt > $1.lastSeenAt }
            return $0.wayfarerId < $1.wayfarerId
        }
        out["peers"] = sorted.map { peerDict($0) }
        out["summary"] = [
            "total": summaryTotal,
            "stale": summaryStale,
            "now_epoch_seconds": nowEpochSeconds,
            "stale_after_seconds": staleAfterSeconds,
        ] as [String: Any]
        return out
    }

    public static func relayList(_ transfers: [Transfer]) -> [String: Any] {
        var out = base(command: "relay.list")
        let sorted = transfers.sorted {
            if $0.lastActivityAt != $1.lastActivityAt { return $0.lastActivityAt > $1.lastActivityAt }
            return $0.transferId < $1.transferId
        }
        out["relay_transfers"] = sorted.map { transferDict($0) }
        out["count"] = sorted.count
        return out
    }

    public static func inventoryAdvertise(manifests: [String], generatedAtUnixMs: Int64, enqueued: Bool) -> [String: Any] {
        var out = base(command: "inventory.advertise")
        let sorted = manifests.sorted()
        out["inventory"] = [
            "generated_at_unix_ms": generatedAtUnixMs,
            "count": sorted.count,
            "manifests": sorted,
            "enqueued": enqueued,
        ] as [String: Any]
        return out
    }

    public static func inventoryRequest(remoteCount: Int, want: [String], enqueued: Bool) -> [String: Any] {
        var out = base(command: "inventory.request")
        let sorted = want.sorted()
        out["remote_count"] = remoteCount
        out["missing_count"] = sorted.count
        out["want"] = sorted
        out["enqueued"] = enqueued
        return out
    }

    public static func inventoryExchange(peerWayfarerId: String, exchange: [String: Any]) -> [String: Any] {
        var out = base(command: "inventory.exchange")
        out["peer_wayfarer_id"] = peerWayfarerId
        out["exchange"] = exchange
        return out
    }

    public static func inventoryGossip(
        nowEpochSeconds: Int64,
        limitPeers: Int,
        peerLimit: Int,
        requestCap: Int,
        staleAfterSeconds: Int64,
        results: [[String: Any]],
        summary: [String: Any]
    ) -> [String: Any] {
        var out = base(command: "inventory.gossip")
        out["gossip"] = [
            "now_epoch_seconds": nowEpochSeconds,
            "limit_peers": limitPeers,
            "peer_limit": peerLimit,
            "request_cap": requestCap,
            "stale_after_seconds": staleAfterSeconds,
        ] as [String: Any]
        out["results"] = results
        out["summary"] = summary
        return out
    }

    public static func httpExchange(
        url: String,
        rounds: Int,
        remoteWayfarerId: String,
        framesPulled: Int,
        framesSent: Int,
        limit: Int,
        requestCap: Int
    ) -> [String: Any] {
        var out = base(command: "http.exchange")
        out["url"] = url
        out["rounds"] = rounds
        out["remote_wayfarer_id"] = remoteWayfarerId
        out["frames_pulled"] = framesPulled
        out["frames_sent"] = framesSent
        out["limit"] = limit
        out["request_cap"] = requestCap
        return out
    }

    public static func remotePush(to: String, advertisedCount: Int, framesSent: Int, requestCap: Int) -> [String: Any] {
        var out = base(command: "remote.push")
        out["to"] = to
        out["advertised_count"] = advertisedCount
        out["frames_sent"] = framesSent
        out["request_cap"] = requestCap
        return out
    }

    private static func identityDict(_ identity: IdentityV1?) -> [String: Any] {
        [
            "wayfarer_id": identity?.wayfarerId.hexString ?? "",
            "short_id": identity?.shortId ?? "",
            "key_type": IdentityV1.keyType,
            "public_key": identity?.signingPublicKeyHex ?? "",
            "exchange_public_key": identity?.exchangePublicKeyHex ?? "",
            "key_fingerprint": identity?.keyFingerprint ?? "",
            "self_certifying": identity?.isSelfCertifying ?? false,
        ]
    }

    private static func peerDict(_ p: Peer) -> [String: Any] {
        [
            "wayfarer_id": p.wayfarerId,
            "short_id": p.shortId,
            "first_seen_at": p.firstSeenAt,
            "last_seen_at": p.lastSeenAt,
            "last_exchange_at": p.lastExchangeAt ?? NSNull(),
        ]
    }

    private static func transferDict(_ t: Transfer) -> [String: Any] {
        [
            "transfer_id": t.transferId,
            "direction": t.direction.rawValue,
            "status": t.status.rawValue,
            "custody": t.custody.rawValue,
            "peer_from": t.peerFrom,
            "peer_to": t.peerTo,
            "created_at": iso8601(t.createdAt),
            "updated_at": iso8601(t.updatedAt),
            "last_activity_at": iso8601(t.lastActivityAt),
            "original_filename": t.originalFilename ?? NSNull(),
            "bytes_total": t.bytesTotal,
            "bytes_sent": t.bytesSent,
            "bytes_received": t.bytesReceived,
            "parts_total": Int(t.partsTotal),
            "parts_sent": Int(t.partsSent),
            "parts_received": Int(t.partsReceived),
            "manifest_hash": t.manifestHash ?? NSNull(),
            "payload_hash": t.payloadHash ?? NSNull(),
            "verified": t.verified,
            "last_error": t.lastError ?? NSNull(),
            "ttl_seconds": t.ttlSeconds ?? NSNull(),
            "expires_at": t.expiresAt.map(iso8601) ?? NSNull(),
            "completed_at": t.completedAt.map(iso8601) ?? NSNull(),
            "evicted": t.evicted,
        ]
    }

    private static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
