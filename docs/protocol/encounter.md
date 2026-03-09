# Encounter Lifecycle and Deterministic Session Semantics

Status: authoritative encounter behavior for transport-neutral multi-bearer gossip.

## 1. Normative language

RFC 2119 terms are normative in this document.

## 2. Deterministic encounter model

An encounter is a temporary peer session over any bearer. Session semantics MUST be identical across LAN, relay, and future bearers.

Session objectives:

1. establish version/identity compatibility,
2. exchange deterministic inventory summary,
3. request and transfer missing objects within fixed budgets,
4. converge idempotently across repeated encounters.

## 3. HELLO and identity derivation

HELLO fields are defined in `docs/protocol/frames.md`.

Identity rules:

1. `node_id` MUST equal lowercase hex `SHA-256(node_pubkey_raw_bytes)`.
2. Node identity SHOULD persist across restarts while key material is unchanged.
3. If identity rotates (new key), peer MUST treat rotated identity as a new node.
4. HELLO metadata MUST NOT be used as sole trust decision input.

## 4. Version mismatch behavior (fail-closed)

1. If `HELLO.version != GOSSIP_VERSION`, encounter MUST fail closed.
2. On mismatch, node MUST stop frame processing for that session.
3. Session termination SHOULD be graceful (close stream / end datagram exchange cleanly).

## 5. Session framing expectations

1. Frame envelope and boundaries MUST follow `docs/protocol/frames.md`.
2. RFC 8949 deterministic CBOR encoding MUST be used for all frames.
3. For stream bearers, decoder MUST process exactly one length-prefixed frame at a time.
4. For datagram bearers, partial frames MUST be rejected.
5. Bearer re-ordering or duplication MUST be handled through idempotent `item_id` processing.

## 6. SUMMARY cadence guidance

1. Node MUST send SUMMARY at session start after HELLO success.
2. Node SHOULD send a refreshed SUMMARY after significant inventory change during long encounters.
3. Node SHOULD send SUMMARY after completing a large transfer batch.
4. Later encounters MUST continue convergence idempotently.

## 6.1 Bloom filter determinism (mandatory)

For identical object sets, compliant implementations MUST produce identical `SUMMARY.bloom_filter` bytes.

Deterministic mapping rules:

1. Hash primitive MUST be SHA-256.
2. For each `item_id` (64-char lowercase hex), derive `item_bytes` by hex-decoding.
3. For hash index `i` in `[0, BLOOM_HASH_COUNT-1]`, compute `digest_i = SHA-256(item_bytes || uint8(i))`.
4. Interpret first 8 bytes of `digest_i` as unsigned 64-bit big-endian integer `v_i`.
5. Compute `bit_index = v_i mod (BLOOM_FILTER_BYTES * 8)`.
6. Compute `byte_index = bit_index // 8`.
7. Compute `bit_offset = bit_index % 8` using LSB0 ordering (bit 0 is least-significant bit).
8. Set `bloom_filter[byte_index] |= (1 << bit_offset)`.

Initial Bloom buffer MUST be all zero bytes.

## 7. Expiry semantics and clock skew

1. `expiry_unix_ms` MUST be UTC Unix epoch milliseconds (`uint64`).
2. Receiver MUST evaluate expiry using local UTC clock.
3. `CLOCK_SKEW_TOLERANCE_MS = 30000` (30s) MUST be applied during acceptance decisions.
4. Object is expired when `now_ms + CLOCK_SKEW_TOLERANCE_MS >= expiry_unix_ms`.
5. Expired objects MUST NOT be requested, accepted, or forwarded.

## 8. Deterministic encounter flow

Mandatory high-level sequence:

1. `HELLO`
2. `SUMMARY`
3. `REQUEST`
4. `TRANSFER`
5. `RECEIPT`

`SUMMARY/REQUEST/TRANSFER/RECEIPT` MAY repeat in-cycle for long sessions, but each frame MUST remain independently valid under frame catalog rules.

## 8.1 Constrained-encounter transfer scheduling (local policy only)

During constrained encounters, nodes MAY prioritize transfer scheduling by local policy (for example: not relay-ingested first, lower `hop_count`, earlier `expiry_unix_ms`, then stable `item_id` tie-break).

This scheduling guidance MUST NOT alter protocol validity, interoperability, or acceptance semantics.

## 9. Transport-neutral correctness constraints

1. Bearers MAY differ in discovery and channel setup.
2. Bearers MUST NOT alter acceptance, rejection, hashing, identity, `expiry_unix_ms`, or hop-count semantics.
3. Linux and iOS implementations MUST share identical RFC 8949 deterministic CBOR and Bloom algorithms.

## 10. Security considerations

- Session admission policy is local, but protocol correctness is global.
- Rate-limiting and abuse controls SHOULD be local policy layers.
- Scoring data MUST remain local-only and MUST NOT be transmitted.
