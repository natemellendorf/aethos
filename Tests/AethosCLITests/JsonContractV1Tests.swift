import AethosCLILib
import AethosCore
import Foundation
import Testing

@Test
func statusJsonContractV1_snapshot() throws {
    // Keep this purely structural/deterministic: no file I/O, no machine-specific paths.
    // This is a schema-only snapshot; values are placeholders.
    let obj = CLIContractV1.status(storeExists: false, identity: nil)

    let h = SnapshotHarness()
    try h.assertSnapshot(name: "status.json.contract.v1") {
        CLIJSON.serializeJSON(obj, indent: 0)
    }
}

@Test
func transfersListJsonContractV1_snapshot() throws {
    let obj = CLIContractV1.transfersList([])
    let h = SnapshotHarness()
    try h.assertSnapshot(name: "transfers.list.json.contract.v1") {
        CLIJSON.serializeJSON(obj, indent: 0)
    }
}

@Test
func peersListJsonContractV1_snapshot() throws {
    let obj = CLIContractV1.peersList(
        peers: [],
        summaryTotal: 0,
        summaryStale: 0,
        nowEpochSeconds: 0,
        staleAfterSeconds: 86400
    )
    let h = SnapshotHarness()
    try h.assertSnapshot(name: "peers.list.json.contract.v1") {
        CLIJSON.serializeJSON(obj, indent: 0)
    }
}

@Test
func inventoryAdvertiseJsonContractV1_snapshot() throws {
    let obj = CLIContractV1.inventoryAdvertise(manifests: [], generatedAtUnixMs: 0, enqueued: true)
    let h = SnapshotHarness()
    try h.assertSnapshot(name: "inventory.advertise.json.contract.v1") {
        CLIJSON.serializeJSON(obj, indent: 0)
    }
}

@Test
func inventoryRequestJsonContractV1_snapshot() throws {
    let obj = CLIContractV1.inventoryRequest(remoteCount: 0, want: [], enqueued: false)
    let h = SnapshotHarness()
    try h.assertSnapshot(name: "inventory.request.json.contract.v1") {
        CLIJSON.serializeJSON(obj, indent: 0)
    }
}

@Test
func httpExchangeJsonContractV1_snapshot() throws {
    let obj = CLIContractV1.httpExchange(
        url: "http://127.0.0.1:8080",
        rounds: 1,
        remoteWayfarerId: "",
        framesPulled: 0,
        framesSent: 0,
        limit: 500,
        requestCap: 200
    )
    let h = SnapshotHarness()
    try h.assertSnapshot(name: "http.exchange.json.contract.v1") {
        CLIJSON.serializeJSON(obj, indent: 0)
    }
}

@Test
func remotePushJsonContractV1_snapshot() throws {
    let obj = CLIContractV1.remotePush(to: "http://127.0.0.1:8080", advertisedCount: 0, framesSent: 0, requestCap: 200)
    let h = SnapshotHarness()
    try h.assertSnapshot(name: "remote.push.json.contract.v1") {
        CLIJSON.serializeJSON(obj, indent: 0)
    }
}

@Test
func relayListJsonContractV1_snapshot() throws {
    let obj = CLIContractV1.relayList([])
    let h = SnapshotHarness()
    try h.assertSnapshot(name: "relay.list.json.contract.v1") {
        CLIJSON.serializeJSON(obj, indent: 0)
    }
}

@Test
func transfersShowJsonContractV1_snapshot() throws {
    let epoch = Date(timeIntervalSince1970: 0)
    let t = Transfer(
        transferId: "00000000-0000-0000-0000-000000000000",
        direction: .outbound,
        peerFrom: "",
        peerTo: "",
        createdAt: epoch,
        updatedAt: epoch,
        lastActivityAt: epoch,
        status: .queued,
        originalFilename: nil,
        bytesTotal: 0,
        bytesSent: 0,
        bytesReceived: 0,
        partsTotal: 0,
        partsSent: 0,
        partsReceived: 0,
        manifestHash: nil,
        payloadHash: nil,
        verified: false,
        lastError: nil,
        custody: .origin,
        ttlSeconds: nil,
        expiresAt: nil,
        completedAt: nil,
        evicted: false
    )
    let obj = CLIContractV1.transfersShow(t)
    let h = SnapshotHarness()
    try h.assertSnapshot(name: "transfers.show.json.contract.v1") {
        CLIJSON.serializeJSON(obj, indent: 0)
    }
}

@Test
func inventoryExchangeJsonContractV1_snapshot() throws {
    let exchange: [String: Any] = [
        "advertised_count": 0,
        "advertised_truncated": false,
        "peer_advertised_count": 0,
        "missing_on_peer_count": 0,
        "requested_count": 0,
        "requested_truncated": false,
        "replayed_manifests": 0,
        "replayed_chunks": 0,
        "receipts_received": 0,
    ]
    let obj = CLIContractV1.inventoryExchange(peerWayfarerId: "", exchange: exchange)
    let h = SnapshotHarness()
    try h.assertSnapshot(name: "inventory.exchange.json.contract.v1") {
        CLIJSON.serializeJSON(obj, indent: 0)
    }
}

@Test
func inventoryGossipJsonContractV1_snapshot() throws {
    let obj = CLIContractV1.inventoryGossip(
        nowEpochSeconds: 0,
        limitPeers: 10,
        peerLimit: 500,
        requestCap: 200,
        staleAfterSeconds: 86400,
        results: [],
        summary: [
            "peers_considered": 0,
            "peers_selected": 0,
            "peers_exchanged_ok": 0,
            "peers_failed": 0,
        ]
    )
    let h = SnapshotHarness()
    try h.assertSnapshot(name: "inventory.gossip.json.contract.v1") {
        CLIJSON.serializeJSON(obj, indent: 0)
    }
}

@Test
func errorJsonContractV1_snapshot() throws {
    let obj = CLIContractV1.error(command: "http.exchange", type: "error", message: "boom")
    let h = SnapshotHarness()
    try h.assertSnapshot(name: "error.json.contract.v1") {
        CLIJSON.serializeJSON(obj, indent: 0)
    }
}

@Test
func messagesListJsonContractV1_snapshot() throws {
    let obj = CLIContractV1.messagesList([])
    let h = SnapshotHarness()
    try h.assertSnapshot(name: "messages.list.json.contract.v1") {
        CLIJSON.serializeJSON(obj, indent: 0)
    }
}

@Test
func messagesShowJsonContractV1_snapshot() throws {
    let msg: [String: Any] = [
        "message_id": String(repeating: "0", count: 64),
        "kind": "message.v2",
        "direction": "inbound",
        "author_wayfarer_id": String(repeating: "a", count: 64),
        "received_from_peer_id": NSNull(),
        "peer_to": NSNull(),
        "created_at": "1970-01-01T00:00:00Z",
        "canonical_hex": "",
        "body_utf8": NSNull(),
    ]
    let obj = CLIContractV1.messagesShow(msg)
    let h = SnapshotHarness()
    try h.assertSnapshot(name: "messages.show.json.contract.v1") {
        CLIJSON.serializeJSON(obj, indent: 0)
    }
}
