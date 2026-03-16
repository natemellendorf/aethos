# ADR-0001: Protocol Contract Source of Truth

- Status: Accepted
- Date: 2026-03-06

## Context

Historically, protocol behavior lived in implementation notes and legacy versioned documents (including the v0.1 relay contract and MVP0 object-format notes).

That made the effective source of truth implicit, and different consumers could treat different docs as normative.

## Decision

`docs/spec/*` and `docs/protocol/*` are now the canonical sources of truth for active protocol contracts.

Implementations MUST conform to active contracts in `docs/spec/*` and `docs/protocol/*`.

For v1 contracts introduced with this ADR:

- `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md`
- `docs/spec/FEDERATION_PROTOCOL_V1.md`
- `docs/spec/RECEIPTS.md`
- `docs/protocol/*` (canonical Gossip v1 upgrade docs and invariants)
- `Fixtures/Protocol/gossip-v1/*` (canonical interoperability fixtures)

Legacy note:

- Historical and migration-era documents are retained separately and are non-normative.

## Consequences

- Existing docs remain valuable context, but are no longer the canonical contract source.
- Archived legacy and migration materials are historical/non-normative.
- Future protocol changes MUST land as explicit updates/new versions under `docs/spec/*`, `docs/protocol/*`, or both when applicable.
