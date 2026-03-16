<p align="center">
  <img src="docs/img/banner.jpg" alt="Aethos banner" width="960">
</p>

# Aethos Gossip Protocol (Gossip V1)

Aethos is a deterministic, store–carry–forward gossip protocol designed for unreliable, intermittent, or constrained links.

`docs/protocol/` is authoritative for Aethos Gossip Protocol (Gossip V1) semantics, invariants, and wire framing.

`docs/spec/` is authoritative for transport/product API contracts (client-relay, federation, receipts).

The canonical transport-neutral gossip protocol is specified in:

- `docs/protocol/gossip.md` (architecture and invariants)
- `docs/protocol/frames.md` (wire frames and validation)
- `docs/protocol/encounter.md` (encounter/session lifecycle)
- `docs/protocol/replication.md` (store-carry-forward replication model)

Reference implementation:

- Protocol engine: `AethosCore/Sources/AethosCore/Protocol/GossipV1/*`
- Transport stream adapter: `AethosCore/Sources/AethosCore/Transport/GossipV1/*`

## Core Design Goals

- Deterministic, content-addressed objects and idempotent convergence.
- Transport-neutral frames with bearer-specific boundaries: datagram bearers MUST carry exactly one complete frame per datagram; stream bearers MUST prefix each frame with a 32-bit big-endian length (see `docs/protocol/frames.md` §2.3).
- Sessionless progress under explicit budgets (items/bytes); safe repetition.
- Fail-closed validation: reject malformed, oversize, expired, or incompatible inputs.
- Strict separation between wire correctness and local policy (scoring, ordering).

## Store–Carry–Forward Gossip

Nodes exchange inventory and replicate objects opportunistically during brief encounters.
Transfers are incremental and tolerate duplication, reordering, partial completion, and repeated sessions.

## Protocol Overview

An encounter is a bounded exchange of frames:

1. `HELLO`: version and node identity advertisement.
2. `SUMMARY`: deterministic Bloom filter of eligible inventory.
3. `REQUEST`: item IDs the peer wants.
4. `TRANSFER`: objects (envelope bytes + metadata) within strict size/item limits.
5. `RECEIPT`: acknowledgement of received item IDs for the immediately preceding transfer.
6. Optional `RELAY_INGEST`: relay durability signal (trusted only on authenticated relay transport).

Frame names, schemas, and limits are defined in `docs/protocol/frames.md`.

## Deterministic Object Identity

Each gossiped object is identified by `item_id = SHA-256(envelope_bytes)` (lowercase hex), where `envelope_bytes` are immutable, canonical serialized Aethos envelope bytes carried as base64url (`envelope_b64`). Deduplication is by `item_id` only.

## Bloom-Based Inventory Exchange

`SUMMARY` carries a fixed-size Bloom filter (`BLOOM_FILTER_BYTES`; currently 2048; defined in `docs/protocol/frames.md`) computed deterministically across implementations. False positives are acceptable; repeated encounters converge without coordination.

## Replication Model

Replication is multi-path (not strict custody transfer). Multiple nodes may hold the same `item_id` concurrently; forwarding does not imply safe deletion. `hop_count` starts at 0 and must increment by exactly 1 on forward and must not regress for the same `item_id`.

See `docs/protocol/replication.md`.

## Relay Interaction

Relays participate in gossip without changing semantics:

- Preserve envelope immutability and deduplicate by `item_id`.
- Emit/accept `RELAY_INGEST` only after durable write.
- Treat `RELAY_INGEST` as authoritative for pruning or replication de-escalation only when received on authenticated relay transport.

See `docs/protocol/gossip.md` and `docs/protocol/frames.md`.

## Documentation Hierarchy

- `docs/protocol/*` — canonical transport-neutral Gossip V1 semantics and wire framing.
- `docs/spec/*` — canonical transport/product API contracts.
- `docs/adr/*` — architectural decisions.
- `docs/audit/*` — non-normative audit reports.
- Historical/non-normative material is intentionally excluded from the active authority hierarchy.

Key active protocol references:

- `docs/protocol/frames.md` (authoritative wire-frame catalog)
- `docs/protocol/gossip.md` (architecture/invariants + source attribution)
- `docs/protocol/encounter.md` (encounter behavior)
- `docs/protocol/replication.md` (store–carry–forward replication contract)
- `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md`
- `docs/spec/FEDERATION_PROTOCOL_V1.md`
- `docs/spec/RECEIPTS.md`
- `docs/adr/ADR-0002-runtime-architecture-gossip-v1.md`
- `Fixtures/Protocol/gossip-v1/`

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE).
