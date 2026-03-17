# Gossip Protocol Architecture (Transport-Neutral, Multi-Bearer)

Status: authoritative protocol architecture for Aethos gossip upgrade.

## 1. Normative language

The key words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** are to be interpreted as described in RFC 2119.

## 2. Authority and scope

1. `docs/protocol/frames.md` is the authoritative wire-frame catalog.
2. This document is the authoritative architecture and invariant contract.
3. Bearer implementations MUST preserve protocol semantics exactly.

## 2.1 Source attribution and precedence

When sources differ, precedence for active contracts is:

1. `docs/protocol/frames.md` for frame schema, wire encoding, and framing boundaries.
2. `docs/protocol/*` for transport-neutral Gossip V1 semantics and invariants.
3. `docs/spec/*` for transport/product API contracts (client-relay, federation, receipts).
4. `docs/adr/*` for architectural decisions and rationale.

Historical and migration-era materials are non-normative and MUST NOT override active contracts.

Implementation alignment note (current repository):

- Active Gossip V1 transfer objects carry `envelope_b64` for deterministic CBOR envelope bytes; `item_id` is derived as `SHA-256(envelope_bytes)`.
- The active Gossip V1 object model and framing semantics are implemented by `AethosCore/Sources/AethosCore/Protocol/GossipV1/*`.

## 3. Protocol invariants (frozen for upgrade)

1. `item_id` MUST be derived from raw canonical serialized envelope bytes and encoded as lowercase hex.
2. Envelope bytes MUST be immutable after creation.
3. Sender identity MUST come from canonical/authenticated object data, never transport metadata.
4. All gossip frames MUST use one shared canonical wire encoding and framing model.
5. `hop_count` MUST increment by exactly 1 on forward and MUST NOT regress.
6. Expired objects (`expiry_unix_ms`) MUST NOT be forwarded.
7. Bloom filter behavior MUST be deterministic across implementations.
8. Deduplication MUST be by `item_id` only.
9. `RELAY_INGEST` MUST be authenticated before affecting pruning or replication policy.
10. Scoring MAY influence preference but MUST NOT affect validity/correctness.
11. Incompatible protocol versions MUST fail closed and end the encounter gracefully.
12. Bearer implementations MUST NOT alter protocol semantics.

## 4. Canonical wire encoding and framing

1. All frames MUST use canonical CBOR with RFC 8949 deterministic encoding.
2. All frames MUST use the frame envelope in `docs/protocol/frames.md`.
3. Datagram bearers MUST carry exactly one frame per datagram.
4. Stream bearers MUST use 32-bit big-endian length-prefixed frame boundaries.
5. Implementations MUST reject frames larger than `MAX_FRAME_BYTES`.

## 5. Deterministic object identity

Gossip object fields:

- `item_id`
- `envelope_b64`
- `expiry_unix_ms`
- `hop_count`

Identity derivation:

1. `envelope_b64` MUST be base64url without padding.
2. `envelope_bytes` are decoded canonical serialized envelope bytes from `envelope_b64`.
3. `item_id = SHA-256(envelope_bytes)`.
4. `item_id` representation MUST be lowercase hexadecimal.
5. `item_id` mismatch MUST cause object rejection.

## 6. Deterministic acceptance/rejection

For `GOSSIP_VERSION=1`, receivers MUST reject any object/frame that violates required schema or limits, including:

- unknown payload fields,
- missing required fields,
- malformed encoding,
- malformed base64url envelope encoding,
- invalid hash derivation,
- oversize frame/object budgets,
- expired objects,
- invalid/overflow `hop_count`.

For `SUMMARY`, receivers MUST require `bloom_filter` and `item_count`, MAY accept optional `preview_item_ids` and `preview_cursor`, and MUST reject any additional unknown payload keys.

`SUMMARY.preview_item_ids` wire order MUST remain bytewise lexicographic by decoded `item_id` bytes per `docs/protocol/frames.md`; deterministic prioritization affects membership selection only and is defined in `docs/protocol/encounter.md` §6.2.

When violations are frame-local and recoverable, receiver MAY continue session; repeated protocol violations SHOULD end session.

## 7. Hop-count monotonicity and regression rules

1. Initial `hop_count` at origin MUST be `0`.
2. Each forwarding action MUST increment `hop_count` by exactly `1`.
3. Values outside `0..65535` MUST be rejected.
4. If a node already stores `item_id` at hop `h_existing`, receiving same `item_id` with `h_incoming < h_existing` MUST be rejected as regression.
5. `h_incoming == h_existing` MAY be accepted as idempotent duplicate.

## 8. Relay ingest trust model

1. RELAY_INGEST MUST be accepted for policy changes only on authenticated relay transport.
2. Nodes MUST NOT prune or de-escalate replication solely on unauthenticated RELAY_INGEST.
3. Relay systems MUST emit RELAY_INGEST only after durable write in relay persistence.
4. Relay ingestion handling MUST be idempotent by `item_id`.

## 9. Frame and transfer budgets

1. `MAX_TRANSFER_ITEMS = 32` and `MAX_TRANSFER_BYTES = 524288` MUST be enforced.
2. `MAX_WANT_ITEMS` and `MAX_FRAME_BYTES` from frame catalog MUST be enforced.
3. Oversize REQUEST/TRANSFER payloads MUST be rejected.

## 10. Transport abstraction

Protocol engine and transport adapter MUST be separate.

Transport responsibilities:

- peer discovery,
- frame delivery,
- authenticated channel properties (where applicable).

Transport implementations MUST NOT modify frame semantics, hash derivation, or acceptance behavior.
Transport peer identifiers are metadata only and MUST NOT override canonical message author attribution.

## 10.1 Relay responsibilities

Relay participants in gossip MUST:

1. preserve envelope immutability,
2. deduplicate by `item_id`,
3. emit `RELAY_INGEST` only after durable write,
4. avoid mutating protocol semantics relative to non-relay peers.

Relay gossip behavior MUST remain idempotent by `item_id`.

## 11. Bloom determinism requirement

The Bloom design parameters and deterministic mapping are defined in encounter and frame documents. All compliant implementations MUST produce identical Bloom bitsets for identical item sets.

## 12. Transfer ordering policy (non-normative for wire correctness)

Implementations MAY apply local transfer prioritization during constrained encounters. The numbered examples below are illustrative local policy (non-normative), not a mandated ordering:

1. objects not yet relay-ingested first,
2. earlier `expiry_unix_ms` first,
3. lower `hop_count` first,
4. relay-reachable or higher-utility paths first when locally known,
5. stable tie-break by `item_id`.

This ordering is local policy only. It MUST NOT change wire validity, interoperability, or acceptance semantics.

## 13. Security considerations

- Enforce authenticated envelope validation prior to trust/use.
- Reject malformed/oversize frames early.
- Never infer sender identity from bearer metadata alone.
- Keep deterministic correctness independent of scoring policy.

## 14. Extension namespace discipline

For extension-safe metadata containers (for example message extension metadata):

- Unknown keys MAY be accepted only inside explicitly extension-safe optional containers.
- Unknown structural fields outside those containers MUST be rejected.
- Reserved namespaces `aethos.*` and `sys.*` are not application extension space and MUST be rejected when carried as third-party extension keys.
