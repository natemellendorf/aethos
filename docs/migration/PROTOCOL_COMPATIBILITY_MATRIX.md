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
| Client hello | `hello.device_id` required in v1 | `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md` (`device_id` REQUIRED) | `VERIFY` | `VERIFY` (reported missing; citation needed) | `VERIFY` | `VERIFY` | Phase 3 | Confirm runtime behavior in relay + iOS, then plan cutover bead |
| Payload encoding | `payload_b64` uses `base64url` without padding | `docs/relay-contract-v0.1.md` (Base64 Encoding section) | `base64url` no padding documented | `VERIFY` | `VERIFY` | `VERIFY` | Phase 3 | Add explicit iOS/client conformance checks |
| Timestamp mapping | `at` vs `received_at` (seconds) vs `receivedAtUnixMs` (milliseconds) | `docs/relay-contract-v0.1.md` + `docs/protocol.md` | `received_at` documented (seconds) | `VERIFY` | `VERIFY` | `TODO` | Phase 3 | Define canonical mapping rules and migration shim |
| Error frames | Structured `error` frame shape | `docs/relay-contract-v0.1.md` (`type`, `code`, `message`) | Documented in relay contract | `VERIFY` | `VERIFY` | `VERIFY` | Phase 3 | Validate actual emitted shape vs docs |
| Receipt vocabulary | `ack`/`ack_ok` semantics vs core `ReceiptV1` vocabulary | `docs/relay-contract-v0.1.md` + `docs/protocol.md` | `ack`/`ack_ok` documented | `VERIFY` | `VERIFY` | `TODO` | Phase 3 | Define mapping between relay ack lifecycle and canonical receipt model |
| Federation acknowledgments | Ack semantics across relays | `VERIFY` | `VERIFY` | `VERIFY` | `VERIFY` | `VERIFY` | Phase 6 | No canonical citation in listed docs; requires federation documentation bead |
| Per-device delivery tracking | Delivery state keyed by device identity | `VERIFY` | `VERIFY` | `VERIFY` | `VERIFY` | `VERIFY` | Phase 3 | Verify behavior and document required identity keys |
| Federation TTL non-extension | Forwarding must not extend original TTL | `docs/relay-contract-v0.1.md` defines `ttl_seconds`; federation rule is `VERIFY` | `VERIFY` | `VERIFY` | `VERIFY` | `VERIFY` | Phase 6 | Add federation TTL semantics doc and conformance tests |
| Hop count / hop limit | Hop increment and loop-limit behavior | `VERIFY` | `VERIFY` | `VERIFY` | `VERIFY` | `VERIFY` | Phase 6 | Requires documented federation forwarding contract |
| Sync protocol | `GOSSIP_SYNC_V1` adoption status | `docs/spec/GOSSIP_SYNC_V1.md` | `VERIFY` | `VERIFY` | `VERIFY` | `DEFERRED` | Phase 4 | Track as future implementation phase; not active in current clients |

## Notes

- `relay-contract-v0.1` documents `base64url` without padding, `ttl_seconds`, `received_at` (seconds), `hello` -> `hello_ok`, and `ack`/`ack_ok` semantics.
- `docs/protocol.md` documents canonical bytes and `ReceiptV1.receivedAtUnixMs` (milliseconds).
- Federation semantics are intentionally marked `VERIFY` where repository citations are missing.

## Related docs

- [Protocol Migration Roadmap](./protocol_update.md)
- [Protocol Architecture](./protocol_architecture.md)
- [Core protocol structures and canonical bytes](../protocol.md)
- [RelayLink v0.1 historical contract](../relay-contract-v0.1.md)
