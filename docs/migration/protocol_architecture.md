# Protocol Architecture (Migration Companion)

Status: Draft companion to `docs/migration/protocol_update.md`

This document maps canonical protocol contracts to architecture layers during migration.

Authoritative semantics rule: `docs/spec/*` defines interoperability semantics. This file tracks migration architecture intent and rollout status only.

## Canonical Contract Set

- `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md`
- `docs/spec/FEDERATION_PROTOCOL_V1.md`
- `docs/spec/RECEIPTS.md`
- `docs/spec/GOSSIP_SYNC_V1.md`

## Sync and Conformance References

- Gossip sync contract: `docs/spec/GOSSIP_SYNC_V1.md`
- Gossip sync fixtures: `docs/migration/GOSSIP_SYNC_CONFORMANCE_FIXTURES.md`
- Compatibility status tracking: `docs/migration/PROTOCOL_COMPATIBILITY_MATRIX.md`

## Phase 4/5 Target-State Components (Kickoff Status)

Status vocabulary: `Specified` / `In progress` / `Not started` / `Implemented`.

| Component | Layer | Status | Architecture note | References |
| --- | --- | --- | --- | --- |
| `GOSSIP_SYNC_V1` contract | Canonical protocol semantics (`docs/spec`) | Specified | Canonical transport-neutral sync semantics are defined in spec and treated as authoritative. | `docs/spec/GOSSIP_SYNC_V1.md`, `docs/migration/GOSSIP_SYNC_CONFORMANCE_FIXTURES.md` |
| Transport-neutral sync engine | Runtime implementation (`aethos`/implementations) | In progress | Engine/session behavior is being integrated to realize the contract without changing canonical semantics in this companion. | `docs/migration/protocol_update.md#10-phase-4--gossip-sync-implementation`, `docs/migration/PROTOCOL_COMPATIBILITY_MATRIX.md` |
| Local peer discovery | Client/runtime network layer | In progress | Discovery remains an implementation concern; contract-level sync semantics remain in `docs/spec/GOSSIP_SYNC_V1.md`. | `docs/migration/protocol_update.md#11-phase-5--lan-discovery-and-local-peer-delivery` |
| Peer-table tracking | Client/runtime state layer | In progress | Peer identity/endpoint/last-seen tracking is treated as runtime state feeding sync eligibility. | `docs/migration/protocol_update.md#step-54--build-peer-table-abstraction`, `docs/migration/PROTOCOL_COMPATIBILITY_MATRIX.md` |
| Discovery-driven sync integration | Runtime orchestration layer | In progress | Discovery-triggered connect-and-sync wiring is active migration work under Phase 5. | `docs/migration/protocol_update.md#step-55--trigger-sync-on-discovery-driven-connection`, `docs/migration/GOSSIP_SYNC_CONFORMANCE_FIXTURES.md` |

## Layering Notes

1. `docs/spec/*` is authoritative for interoperability semantics.
2. `docs/protocol.md` remains authoritative for canonical bytes and core structures.
3. `docs/migration/*` tracks rollout sequencing, compatibility, fixture/test readiness, and implementation status.
4. Component statuses in this file and the compatibility matrix are migration scoreboard signals; they do not change protocol semantics.
