# Protocol Compatibility Matrix

## Purpose

Track protocol compatibility status across repos during migration. Use this matrix to plan bead sequencing and keep divergence decisions explicit.

Related roadmap: [Protocol Migration Roadmap](./protocol_update.md)

## Status vocabulary

- `OK`: Confirmed aligned with cited behavior.
- `TODO`: Known gap with planned migration work.
- `VERIFY`: Not yet confirmed from repository evidence.
- `DEFERRED`: Intentionally postponed to a later phase.
- `OUT-OF-SCOPE`: Not part of MVP0 migration scope.

## Matrix

| Area | Feature / Semantic | Canonical Spec | aethos-relay Current | aethos-ios Current | Other Clients | Status | Migration Phase | Planned Bead / Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Client hello | `hello.device_id` required in v1 | [CLIENT_RELAY_PROTOCOL_V1](../spec/CLIENT_RELAY_PROTOCOL_V1.md) (`device_id` REQUIRED) | `VERIFY` | `VERIFY` (reported missing; citation needed) | `VERIFY` | `VERIFY` | Phase 3 | Confirm runtime behavior in relay + iOS, then plan cutover bead |
| Payload encoding | `payload_b64` uses `base64url` without padding | [CLIENT_RELAY_PROTOCOL_V1](../spec/CLIENT_RELAY_PROTOCOL_V1.md) (`payload_b64` base64url; CBOR payload) + [RelayLink v0.1](../relay-contract-v0.1.md) (historical) | `base64url` no padding documented | `VERIFY` | `VERIFY` | `VERIFY` | Phase 3 | Add explicit iOS/client conformance checks |
| Timestamp mapping | `received_at` (Unix seconds) vs `ReceiptV1.receivedAtUnixMs` (Unix ms) | [CLIENT_RELAY_PROTOCOL_V1](../spec/CLIENT_RELAY_PROTOCOL_V1.md) (`received_at`) + [protocol.md](../protocol.md) (`ReceiptV1.receivedAtUnixMs`) | `received_at` documented (seconds) | `VERIFY` | `VERIFY` | `TODO` | Phase 3 | Define canonical mapping rules and migration shim |
| Error frames | Structured `error` frame shape | [CLIENT_RELAY_PROTOCOL_V1](../spec/CLIENT_RELAY_PROTOCOL_V1.md) (`type`, `code`, `message`) | Documented in relay contract | `VERIFY` | `VERIFY` | `VERIFY` | Phase 3 | Validate actual emitted shape vs docs |
| Receipt vocabulary | `ack`/`ack_ok` semantics vs core `ReceiptV1` vocabulary | [CLIENT_RELAY_PROTOCOL_V1](../spec/CLIENT_RELAY_PROTOCOL_V1.md) + [RECEIPTS](../spec/RECEIPTS.md) + [protocol.md](../protocol.md) | `ack`/`ack_ok` documented | `VERIFY` | `VERIFY` | `TODO` | Phase 3 | Define mapping between relay ack lifecycle and canonical receipt model |
| Federation acknowledgments | Ack semantics across relays | [FEDERATION_PROTOCOL_V1](../spec/FEDERATION_PROTOCOL_V1.md) (`relay_ack`) | `VERIFY` | `VERIFY` | `VERIFY` | `VERIFY` | Phase 6 | Confirm relay implementation behavior against federation ack contract |
| Per-device delivery tracking | Delivery state keyed by device identity | [CLIENT_RELAY_PROTOCOL_V1](../spec/CLIENT_RELAY_PROTOCOL_V1.md) (per-device tracking by `(wayfarer_id, device_id, msg_id)`) | `VERIFY` | `VERIFY` | `VERIFY` | `VERIFY` | Phase 3 | Verify behavior and document required identity keys |
| Federation TTL non-extension | Forwarding must not extend original TTL | [FEDERATION_PROTOCOL_V1](../spec/FEDERATION_PROTOCOL_V1.md) (`expires_at` immutable; TTL non-extension) | `VERIFY` | `VERIFY` | `VERIFY` | `VERIFY` | Phase 6 | Confirm relay behavior and add federation TTL conformance tests |
| Hop count / hop limit | Hop increment and loop-limit behavior | [FEDERATION_PROTOCOL_V1](../spec/FEDERATION_PROTOCOL_V1.md) (`hop_count`, `MAX_HOPS`, `seen_relays` loop prevention) | `VERIFY` | `VERIFY` | `VERIFY` | `VERIFY` | Phase 6 | Confirm hop-limit and loop-prevention behavior in running relays |
| Sync protocol | `GOSSIP_SYNC_V1` adoption status | [GOSSIP_SYNC_V1](../spec/GOSSIP_SYNC_V1.md) (future draft, non-normative) | `VERIFY` | `VERIFY` | `VERIFY` | `DEFERRED` | Phase 4 | Track as future implementation phase; not active in current clients |

## Notes

- [RelayLink v0.1](../relay-contract-v0.1.md) documents `base64url` without padding, `ttl_seconds`, `received_at` (seconds), `hello` -> `hello_ok`, and `ack`/`ack_ok` semantics.
- [Core protocol](../protocol.md) documents canonical bytes and `ReceiptV1.receivedAtUnixMs` (milliseconds).
- Federation contract exists in [FEDERATION_PROTOCOL_V1](../spec/FEDERATION_PROTOCOL_V1.md); implementation conformance remains `VERIFY` until confirmed.

## Related docs

- [Protocol Migration Roadmap](./protocol_update.md)
- [Protocol Architecture](./protocol_architecture.md)
- [Core protocol structures and canonical bytes](../protocol.md)
- [RelayLink v0.1 historical contract](../relay-contract-v0.1.md)
