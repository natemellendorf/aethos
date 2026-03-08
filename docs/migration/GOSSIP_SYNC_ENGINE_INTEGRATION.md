# Gossip Sync Engine Integration (Transport-Neutral)

`GossipSyncEngine` implements `docs/spec/GOSSIP_SYNC_V1.md` as transport-neutral runtime logic.

## Wiring flow

1. **Connection established/authenticated**: construct `GossipSyncEngine` with runtime interfaces.
2. **Session started**: call `startSession(with:nowUnixMs:)` to emit `inventory_summary`.
3. **Inbound frame routing**: decode inbound frame and call `handleInboundSyncFrame(_:from:nowUnixMs:)`.
4. **Receipt persistence**: implement `GossipReceiptRecording` to persist sync receipts.
5. **Disconnect/cancel safety**: call `connectionDidClose(with:)` or `cancelSession(with:)`; resume via `startSession`/`resumeSession`.

```swift
let engine = try GossipSyncEngine(
    localWayfarerId: localWayfarerId,
    inventoryProvider: inventoryProvider,
    messageLoader: messageLoader,
    receiptRecorder: receiptRecorder,
    transportSender: transportSender,
    inboundTransferHandler: inboundTransferHandler
)

// Connection established
try engine.startSession(with: peerWayfarerId, nowUnixMs: nowMs)

// Inbound sync frame from any transport (relay/LAN/direct)
let frame = try GossipSyncFrameCodec.decodeJSONData(inboundData)
let result = try engine.handleInboundSyncFrame(frame, from: peerWayfarerId, nowUnixMs: nowMs)
```

## MVP0 limits and hardening

- `inventory_summary` and `missing_request` are enforced as single-page in MVP0 (`page=1`, `has_more=false`); multi-page attempts transition the session to `retry_pending`.
- Inbound frame handling enforces configurable caps for inventory items, missing item IDs, transfer items, and decoded envelope bytes.
- Per-session state retention for idempotency tracking and announced inventory is bounded with drop-oldest eviction.
