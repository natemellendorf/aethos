# Aethos Gossip Frames v1 (Authoritative Catalog)

Status: **Authoritative** frame catalog for the gossip protocol upgrade.

This document is the single source of truth for frame names, field definitions, encoding, validation, and size limits.

## 1. Normative language

The key words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** are to be interpreted as described in RFC 2119.

## 2. Canonical wire model

### 2.1 Encoding

1. All gossip frames **MUST** be encoded as canonical CBOR using **RFC 8949 deterministic encoding**.
2. Implementations **MUST** follow RFC 8949 deterministic map key ordering and shortest-form integer encoding.
3. Floating-point values **MUST NOT** be used in gossip frames.
4. Integer values **MUST** be encoded as unsigned integers unless explicitly specified otherwise.

### 2.2 Frame envelope

All frames **MUST** use this envelope:

```cbor
{
  type: tstr,
  payload: map
}
```

- `type` **MUST** be one of: `"HELLO"`, `"SUMMARY"`, `"REQUEST"`, `"TRANSFER"`, `"RECEIPT"`, `"RELAY_INGEST"`.
- `payload` key handling for `GOSSIP_VERSION=1`:
  - For all frame types except `SUMMARY`, payload keys **MUST** match exactly the required fields for that frame type.
  - For `SUMMARY`, payload **MUST** include required fields, MAY include defined optional preview fields, and unknown payload keys **SHOULD** be ignored for forward compatibility.
- Unknown top-level envelope keys **MUST** be ignored for forward compatibility.

Protocol magic decision for v1:

- A top-level `magic` field is **intentionally omitted** in v1.
- Implementations **MUST NOT** require `magic` for v1 frame acceptance.

### 2.3 Frame boundaries by bearer

- Datagram bearers: one datagram **MUST** contain exactly one complete frame.
- Stream bearers: each frame **MUST** be prefixed by a 32-bit big-endian unsigned length (`frame_len`), followed by exactly `frame_len` bytes of canonical CBOR envelope.
- `frame_len` **MUST NOT** exceed `MAX_FRAME_BYTES`.

## 3. Common scalar definitions

- `item_id`: lowercase hex SHA-256 digest, exactly 64 chars (`[0-9a-f]{64}`).
- `node_id`: lowercase hex SHA-256 digest, exactly 64 chars.
- `node_pubkey`: Ed25519 public key bytes, encoded as base64url without padding.
- `expiry_unix_ms`: unsigned 64-bit integer UTC epoch milliseconds.
- `hop_count`: unsigned 16-bit integer.

## 4. Protocol limits (v1)

- `GOSSIP_VERSION = 1`
- `MAX_FRAME_BYTES = 1048576` (1 MiB)
- `MAX_WANT_ITEMS = 256`
- `MAX_TRANSFER_ITEMS = 32`
- `MAX_TRANSFER_BYTES = 524288`
- `BLOOM_FILTER_BYTES = 2048`
- `BLOOM_HASH_COUNT = 4`
- `CLOCK_SKEW_TOLERANCE_MS = 30000`

Oversize or malformed behavior:

1. Frames exceeding limits **MUST** be rejected.
2. Receiver **MUST** continue session only if violation is recoverable and local policy permits.
3. Repeated oversize violations **SHOULD** terminate encounter.

## 5. Frame definitions

### 5.1 HELLO (`type="HELLO"`)

Required payload fields:

- `version: uint`
- `node_id: tstr`
- `node_pubkey: tstr`
- `capabilities: array<tstr>`
- `propagation_class: tstr`
- `max_want: uint`
- `max_transfer: uint`

Validation:

1. `version` **MUST** equal `GOSSIP_VERSION`.
2. `node_id` **MUST** equal lowercase hex `SHA-256(node_pubkey_raw_bytes)`.
3. `max_want` **MUST** be `1..MAX_WANT_ITEMS`.
4. `max_transfer` **MUST** be `1..MAX_TRANSFER_ITEMS`.

### 5.2 SUMMARY (`type="SUMMARY"`)

Required payload fields:

- `bloom_filter: bstr` (exactly `BLOOM_FILTER_BYTES` bytes)
- `item_count: uint`

Optional payload fields:

- `preview_item_ids: array<item_id>`
- `preview_cursor: item_id`

Validation:

1. `bloom_filter` length **MUST** equal `BLOOM_FILTER_BYTES`.
2. `item_count` **MUST** equal local eligible object count at emission time.
3. `preview_item_ids` length **MUST** be `<= MAX_SUMMARY_PREVIEW_ITEMS`.
4. `preview_item_ids` entries **MUST** be unique.
5. `preview_item_ids` entries **MUST** be sorted by bytewise lexicographic order of decoded digest bytes (ascending).
6. If `preview_item_ids` is empty, `preview_cursor` **MUST** be absent.
7. If `preview_cursor` is present, it **MUST** equal the last element of `preview_item_ids`.

### 5.3 REQUEST (`type="REQUEST"`)

Required payload fields:

- `want: array<item_id>`

Validation:

1. `want` length **MUST** be `<= min(peer.max_want, MAX_WANT_ITEMS)`.
2. `want` entries **MUST** be unique by `item_id` (duplicates are forbidden).
3. `want` entries **MUST** be sorted by bytewise lexicographic order of the decoded `item_id` digest bytes (ascending). Ordering **MUST NOT** be based on hex string ordering.
4. Receivers **MUST** reject frames with unsorted `want`.
5. Unknown/malformed `item_id` entries **MUST** be rejected.
6. `want` MAY be empty. An empty `want` is a valid no-op request.

### 5.4 TRANSFER (`type="TRANSFER"`)

Required payload fields:

- `objects: array<object>` where each object is:
  - `item_id: tstr`
  - `envelope_b64: tstr` (base64url, no padding)
  - `expiry_unix_ms: uint`
  - `hop_count: uint`

Validation:

1. Object count **MUST** be `<= MAX_TRANSFER_ITEMS`.
2. Total decoded envelope bytes across `objects` **MUST** be `<= MAX_TRANSFER_BYTES`.
3. `envelope_b64` **MUST** be base64url without padding of the canonical RFC 8949 deterministic CBOR envelope bytes.
4. Decoded `envelope_b64` bytes **MUST** be canonical serialized envelope bytes.
5. `item_id` **MUST** equal lowercase hex `SHA-256(envelope_bytes)` where `envelope_bytes` are decoded from `envelope_b64`.
6. `hop_count` **MUST** be `0..65535`.
7. Expired objects (`now_ms + CLOCK_SKEW_TOLERANCE_MS >= expiry_unix_ms`) **MUST NOT** be accepted.

Mixed-validity semantics:

1. Receivers MUST validate `objects` independently, in the order provided.
2. If one object is invalid, the receiver MUST reject that object but MUST continue validating subsequent objects.
3. A receiver MUST accept all valid objects even when one or more objects in the same frame are invalid.
4. Object-level rejections MUST be treated as non-fatal (they MUST NOT terminate the encounter).

### 5.5 RECEIPT (`type="RECEIPT"`)

Required payload fields:

- `received: array<item_id>`

Validation:

1. `received` entries **MUST** be unique.
2. `received` entries **MUST** be subset of the immediately preceding valid `TRANSFER` object IDs in that direction.

### 5.6 RELAY_INGEST (`type="RELAY_INGEST"`)

Required payload fields:

- `item_ids: array<item_id>`

Validation and trust:

1. `item_ids` entries **MUST** be unique.
2. RELAY_INGEST **MUST** be trusted only when received on authenticated relay transport.
3. Unauthenticated RELAY_INGEST **MUST NOT** influence pruning or replication de-escalation.

## 6. Deterministic rejection/acceptance rules

1. Deduplication **MUST** be by `item_id` only.
2. Unknown frame `type` **MUST** be rejected.
3. Missing required fields **MUST** be rejected.
4. Invalid hash, malformed encoding, malformed base64url, or expired objects **MUST** be rejected.
5. Bearer metadata **MUST NOT** alter acceptance semantics.

## 7. Forwarding semantics anchor

When forwarding objects:

1. Envelope bytes **MUST NOT** be modified.
2. `hop_count` **MUST** increment by exactly 1.
3. Forwarders **MUST NOT** emit values causing overflow.
