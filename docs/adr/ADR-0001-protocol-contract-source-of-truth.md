# ADR-0001: Protocol Contract Source of Truth

- Status: Accepted
- Date: 2026-03-06

## Context

Historically, protocol behavior lived in implementation notes and versioned docs such as:

- `docs/relay-contract-v0.1.md` (client-relay JSON/WebSocket contract)
- `docs/protocol.md` (core Aethos canonical structures and byte encoding)

That made the effective source of truth implicit, and different consumers could treat different docs as normative.

## Decision

`docs/spec/*` is now the canonical source of truth for wire-level protocol contracts.

Implementations MUST conform to versioned specs in `docs/spec/*`.

For v1 contracts introduced with this ADR:

- `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md`
- `docs/spec/FEDERATION_PROTOCOL_V1.md`
- `docs/spec/RECEIPTS.md`
- `docs/spec/GOSSIP_SYNC_V1.md` (future-facing, non-normative)

## Consequences

- Existing docs remain valuable context, but are no longer the canonical contract source.
- `docs/relay-contract-v0.1.md` is treated as historical/legacy reference.
- `docs/protocol.md` remains canonical for core data model and canonical byte encoding primitives used by specs.
- Future protocol changes MUST land as explicit updates/new versions under `docs/spec/*`.
