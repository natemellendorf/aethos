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
