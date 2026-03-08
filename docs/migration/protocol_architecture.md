# Protocol Architecture (Migration Companion)

Status: Draft companion to `docs/migration/protocol_update.md`

This document maps canonical protocol contracts to architecture layers during migration.

## Canonical Contract Set

- `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md`
- `docs/spec/FEDERATION_PROTOCOL_V1.md`
- `docs/spec/RECEIPTS.md`
- `docs/spec/GOSSIP_SYNC_V1.md`

## Sync and Conformance References

- Gossip sync contract: `docs/spec/GOSSIP_SYNC_V1.md`
- Gossip sync fixtures: `docs/migration/GOSSIP_SYNC_CONFORMANCE_FIXTURES.md`
- Compatibility status tracking: `docs/migration/PROTOCOL_COMPATIBILITY_MATRIX.md`

## Layering Notes

1. `docs/spec/*` is authoritative for interoperability semantics.
2. `docs/protocol.md` remains authoritative for canonical bytes and core structures.
3. `docs/migration/*` tracks rollout sequencing, compatibility, and fixture/test readiness.
