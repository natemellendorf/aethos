# Protocol Architecture (Migration Companion)

> Archived migration document (historical, non-normative).
> This architecture companion is retained for migration history only.
> Active normative protocol contracts are defined in `docs/protocol/*` and `docs/spec/*`.

Status: Draft companion to `docs/archive/migration/protocol_update.md`

This document maps canonical protocol contracts to architecture layers during migration.

Authoritative semantics rule: `docs/spec/*` defines interoperability semantics. This file tracks migration architecture intent and rollout status only.

## Canonical Contract Set

- `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md`
- `docs/spec/FEDERATION_PROTOCOL_V1.md`
- `docs/spec/RECEIPTS.md`
- Gossip v1 upgrade docs: `docs/protocol/*`

## Sync and Conformance References

- Gossip v1 upgrade docs: `docs/protocol/*`
- Gossip v1 interoperability fixtures: `Fixtures/Protocol/gossip-v1/*`
- Compatibility status tracking: `docs/archive/migration/PROTOCOL_COMPATIBILITY_MATRIX.md`

## Phase 4/5 Target-State Components (Kickoff Status)

Status vocabulary: `Specified` / `In progress` / `Not started` / `Implemented`.

| Component | Layer | Status | Architecture note | References |
| --- | --- | --- | --- | --- |
| Gossip v1 upgrade docs | Canonical protocol semantics (`docs/protocol`) | Specified | Canonical Gossip v1 upgrade semantics are defined in `docs/protocol/*` and treated as authoritative. | `docs/protocol/*`, `Fixtures/Protocol/gossip-v1/*` |
| Transport-neutral Gossip V1 runtime | Runtime implementation (`aethos`/implementations) | In progress | Gossip V1 session behavior is being integrated to realize the contract without changing canonical semantics in this companion. | `docs/archive/migration/protocol_update.md#10-phase-4--gossip-v1-implementation`, `docs/archive/migration/PROTOCOL_COMPATIBILITY_MATRIX.md` |
| Local peer discovery | Client/runtime network layer | In progress | Discovery remains an implementation concern; contract-level gossip semantics remain in `docs/protocol/*`. | `docs/archive/migration/protocol_update.md#11-phase-5--lan-discovery-and-local-peer-delivery` |
| Peer-table tracking | Client/runtime state layer | In progress | Peer identity/endpoint/last-seen tracking is treated as runtime state feeding sync eligibility. | `docs/archive/migration/protocol_update.md#step-54--build-peer-table-abstraction`, `docs/archive/migration/PROTOCOL_COMPATIBILITY_MATRIX.md` |
| Discovery-driven sync integration | Runtime orchestration layer | In progress | Discovery-triggered connect-and-gossip wiring is active migration work under Phase 5. | `docs/archive/migration/protocol_update.md#step-55--trigger-sync-on-discovery-driven-connection`, `docs/protocol/gossip.md` |

## Layering Notes

1. `docs/spec/*` is authoritative for interoperability semantics.
2. `docs/protocol/*` remains authoritative for canonical bytes and core structures.
3. `docs/archive/migration/*` tracks rollout sequencing, compatibility, fixture/test readiness, and implementation status.
4. Component statuses in this file and the compatibility matrix are migration scoreboard signals; they do not change protocol semantics.
