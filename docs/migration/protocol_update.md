# Protocol Migration Roadmap

Status: Draft

This is the working roadmap for protocol migration beads in `aethos`.

## Supporting docs

- [Protocol Compatibility Matrix](./PROTOCOL_COMPATIBILITY_MATRIX.md)
- [Protocol Architecture](./protocol_architecture.md)

## Canonical references in this repo

- [Core protocol structures and canonical bytes](../protocol.md)
- [RelayLink v0.1 historical contract](../relay-contract-v0.1.md)

## Phase 0 - Foundation

Canonical protocol ownership is in `aethos` and tracked in current specs and ADRs. Keep this phase focused on source-of-truth clarity and cross-repo references.

## Phase 1 — Divergence Audit

Record implementation differences before behavior changes:

- Keep the matrix in `docs/migration/PROTOCOL_COMPATIBILITY_MATRIX.md` current.
- Capture `VERIFY` items with citations, then split into bead-sized follow-ups.
- Mark each divergence as `OK`, `TODO`, `VERIFY`, `DEFERRED`, or `OUT-OF-SCOPE`.

Exit signal: no material protocol gap is undocumented.

## Phase 2 - Relay Stabilization

Stabilize and isolate existing relay behavior without changing semantics. This keeps alignment work low-risk and auditable.

## Phase 3 - Protocol Alignment

Resolve high-priority divergences one semantic change at a time (identity fields, timestamp mapping, encoding, error vocabulary, receipt mapping).

Exit signal: client and relay behavior match documented contracts or explicit migration shims.

## Phase 4 — Gossip Sync Implementation

Introduce transport-neutral sync semantics for node-to-node exchange (`relay<->relay`, `relay<->client`, `client<->client`).

- Keep `GOSSIP_SYNC_V1` work tracked as future-facing until implementation beads start.
- Require idempotent inventory exchange and receipt-driven dedupe semantics.

## Phase 5 — LAN Discovery and Local Peer Delivery

Enable local discovery and direct peer sync on LAN while preserving protocol contract boundaries.

- Discovery details remain implementation-specific.
- Sync semantics remain contract-driven and transport-neutral.

## Phase 6 — Federation Evolution

Decide whether federation remains a distinct protocol path or converges with shared sync primitives.

- Keep federation implementation conformance `VERIFY` until confirmed against [docs/spec/FEDERATION_PROTOCOL_V1.md](../spec/FEDERATION_PROTOCOL_V1.md) and conformance tests land.
- Land compatibility tests before any federation semantic cutover.

## Bead usage notes

- Prefer one protocol semantic per bead.
- Update the matrix and architecture docs in the same PR when semantics move.
- Use `TBD`/`VERIFY` when repository evidence is missing.
