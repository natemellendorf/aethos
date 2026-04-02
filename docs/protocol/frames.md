# Aethos Gossip Frames v1 (Authoritative Catalog)

Status: **Authoritative** frame catalog for the gossip protocol upgrade.

This document is the single source of truth for frame names, field definitions, encoding, validation, and size limits.

Source attribution note: see `docs/protocol/gossip.md` §2.1 for active-contract precedence across protocol/spec/ADR documents.

## 1. Normative language

The key words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** are to be interpreted as described in RFC 2119.

## 2. Canonical wire model

Frames are bearer-agnostic protocol objects. Bearers differ only in frame-boundary carriage (§2.3) and session/discovery orchestration outside this catalog.

Bearer switching/selection semantics are local runtime behavior and MUST NOT introduce new frame types, envelope keys, or payload keys in Gossip V1.

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
  - Payload keys **MUST** match exactly the defined schema for that frame type.
  - For `SUMMARY`, allowed payload keys are required `bloom_filter`, `item_count` and optional `preview_item_ids`, `preview_cursor`.
  - Any unknown payload key **MUST** cause frame rejection.
- Unknown top-level envelope keys **MUST** be ignored for forward compatibility.

Protocol magic decision for v1:

- A top-level `magic` field is **intentionally omitted** in v1.
- Implementations **MUST NOT** require `magic` for v1 frame acceptance.

### 2.3 Frame boundaries by bearer

- Datagram bearers: one datagram **MUST** contain exactly one complete frame.
- Stream bearers: each frame **MUST** be prefixed by a 32-bit big-endian unsigned length (`frame_len`), followed by exactly `frame_len` bytes of canonical CBOR envelope.
- `frame_len` **MUST NOT** exceed `MAX_FRAME_BYTES`.

Relay binary frame type space allocation (for `RelayFrame` transport framing):

- `0x01...0x0F`: legacy/control
- `0x10...0x1F`: client-relay operational frames
- `0x20...0x2F`: relay-relay/federation scaffold frames
- `0x30...0xEF`: reserved for future protocol assignment
- `0xF0...0xFF`: reserved error/control escape space

Values in reserved ranges that are not explicitly assigned **MUST** be rejected.

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
- `MAX_SUMMARY_PREVIEW_ITEMS = 64`
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
5. `preview_item_ids` entries **MUST** be sorted by bytewise lexicographic order of decoded digest bytes (ascending), comparing each byte as an unsigned value in `[0, 255]`.
   - Ordering **MUST NOT** be based on hex string ordering.
   - This wire-ordering requirement is normative and independent of sender-side prioritization policy.
   - Any prioritization (for example urgent-first by expiry/hop) can only affect which IDs are selected for membership, not the transmitted array order.
6. If `preview_item_ids` is empty, `preview_cursor` **MUST** be absent.
7. If `preview_cursor` is present, it **MUST** equal the last element of `preview_item_ids`.
8. Payload keys **MUST** be limited to `bloom_filter`, `item_count`, `preview_item_ids`, `preview_cursor`; unknown keys **MUST** be rejected.

Selection guidance for deterministic preview membership is defined in `docs/protocol/encounter.md` §6.2; prioritization affects membership only, while on-wire ordering MUST remain canonical and receiver validation MUST enforce sorted `preview_item_ids` plus the `preview_cursor` invariant above.

### 5.3 REQUEST (`type="REQUEST"`)

Required payload fields:

- `want: array<item_id>`

Validation:

1. `want` length **MUST** be `<= min(peer.max_want, MAX_WANT_ITEMS)`.
2. `want` entries **MUST** be unique by `item_id` (duplicates are forbidden).
3. `want` entries **MUST** be sorted by bytewise lexicographic order of the decoded `item_id` digest bytes (ascending), comparing each byte as an unsigned value in `[0, 255]`. Ordering **MUST NOT** be based on hex string ordering.
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

#### 5.4.1 Canonical Envelope schema and serialization semantics

The Envelope is the canonical payload unit in gossip transfer. It is encoded as a canonical CBOR map.

Canonical Envelope schema (required keys):

```cbor
{
  to_wayfarer_id: bstr(32),
  manifest_id: bstr(32),
  body: bstr,
  author_pubkey: bstr(32),
  author_sig: bstr(64)
}
```

Field definitions:

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `to_wayfarer_id` | `bstr(32)` | Yes | 32-byte destination Wayfarer identifier. |
| `manifest_id` | `bstr(32)` | Yes | 32-byte manifest identifier for the payload. |
| `body` | `bstr` | Yes | Opaque payload bytes carried by the envelope. |
| `author_pubkey` | `bstr(32)` | Yes | Ed25519 author public key bytes. |
| `author_sig` | `bstr(64)` | Yes | Ed25519 signature over the canonical envelope signing payload. |

Deterministic sender derivation (normative):

1. The sender identity for a Gossip V1 envelope **MUST** be derived only from `author_pubkey`.
2. `wayfarer_id = SHA-256(author_pubkey)` is the only permitted derivation.
3. Alternative sender identifiers in envelope/body metadata **MUST NOT** be trusted.

Canonical signing payload and signature (normative):

1. Signing payload **MUST** be reconstructed exactly as `CanonicalCBOR({to_wayfarer_id, manifest_id, body})`.
2. Field set for signing payload **MUST** be exactly `to_wayfarer_id`, `manifest_id`, `body` (no extras).
3. CBOR map encoding for signing payload **MUST** use RFC 8949 deterministic ordering.
4. Domain separator **MUST** be the exact UTF-8 byte string `"AETHOS_ENVELOPE_V1"`.
5. Signature digest **MUST** be `SHA-256("AETHOS_ENVELOPE_V1" || signing_payload)`.
6. Signature value **MUST** be `author_sig = Sign(author_privkey, signature_digest)` using Ed25519.

Canonical serialization requirements:

1. Envelope serialization **MUST** use canonical deterministic CBOR encoding (RFC 8949 deterministic encoding).
2. Envelope map keys **MUST** be UTF-8 strings.
3. Envelope map keys **MUST** follow canonical CBOR key ordering.
4. Implementations **MUST** produce deterministic output bytes for the same logical envelope.
5. Pseudo procedure: `envelope_bytes = CBOR.canonical_encode(Envelope)`.
6. Non-canonical CBOR, JSON, and custom binary envelope formats **MUST NOT** be used for gossip transfer.

Item ID derivation:

1. `item_id` **MUST** be derived as `SHA256(envelope_bytes)`.
2. The hash **MUST** be computed over the exact serialized envelope bytes.
3. Any serialization change changes `item_id`.
4. Because `author_pubkey` and `author_sig` are required envelope fields, different authors (or signatures) for the same `{to_wayfarer_id, manifest_id, body}` produce different `item_id` values.
5. Relays **MUST NOT** modify envelope bytes.

TRANSFER frame encoding requirements:

1. `TRANSFER.objects[].envelope_b64` **MUST** contain `base64url(envelope_bytes)`.
2. `envelope_b64` **MUST** use the base64url alphabet with no padding.
3. `envelope_b64` content **MUST** represent canonical envelope bytes exactly.

Short JSON example:

```json
{
  "type": "TRANSFER",
  "payload": {
    "objects": [
      {
        "item_id": "4d7d8d41f37f7d3cf2f0e8d0df43c275ec8d6ca1f8d89a78fb2f932f72f31c5a",
        "envelope_b64": "omRib2R5RWhlbGxva21hbmlmZXN0X2lkWCBERERERERERERERERERERERERERERERERERERERERERW50b193YXlmYXJlcl9pZFggQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkI",
        "expiry_unix_ms": 1735689600000,
        "hop_count": 0
      }
    ]
  }
}
```

Decoder validation rules:

1. Decoder **MUST** base64url-decode `envelope_b64`.
2. Decoder **MUST** verify `sha256(decoded_envelope_bytes)` equals the declared `item_id`.
3. Decoder **MUST** decode `decoded_envelope_bytes` as canonical CBOR.
4. Decoder **MUST** extract required fields `to_wayfarer_id`, `manifest_id`, `body`, `author_pubkey`, `author_sig`.
5. Decoder **MUST** reconstruct `signing_payload = CanonicalCBOR({to_wayfarer_id, manifest_id, body})` exactly.
6. Decoder **MUST** verify `author_sig` against `SHA-256("AETHOS_ENVELOPE_V1" || signing_payload)` using `author_pubkey`.
7. Decoder **MUST** derive sender `wayfarer_id = SHA-256(author_pubkey)` and use only this derived identity for author attribution.
8. Any missing required field, signature failure, malformed field length, or payload reconstruction mismatch **MUST** be rejected fail-closed.
9. Invalid objects **MUST** be rejected.
10. Rejection of one object **MUST NOT** terminate processing of other objects in the same `TRANSFER` frame.

Forward compatibility:

1. For Gossip V1 envelopes, receiver validation **MUST** require the exact field set and reject unknown envelope keys.
2. Future envelope versions **MAY** define expanded schemas under explicit version negotiation.

Security properties:

1. Canonical serialization provides integrity-stable hashing.
2. Deterministic encoding provides deterministic deduplication by `item_id`.
3. Relay neutrality requires relays to treat envelope bytes as immutable.
4. Relays **MUST NOT** modify `author_pubkey`, modify `author_sig`, re-sign envelopes, or wrap envelopes with alternate author metadata.

Implementation guidance:

| Language | Library | Guidance |
| --- | --- | --- |
| Go | `fxamacker/cbor` | **MUST** enable canonical/deterministic encoding mode. |
| Rust | `serde_cbor` (deterministic mode) | **MUST** enable deterministic/canonical serialization mode. |
| Swift | `SwiftCBOR` | **MUST** configure canonical CBOR emission. |

Testing recommendations:

1. Implementations **SHOULD** include test vectors for deterministic envelope bytes.
2. Implementations **SHOULD** include test vectors for canonical key ordering.
3. Implementations **SHOULD** include test vectors for `item_id` hash derivation from serialized bytes.
4. Implementations **SHOULD** include test vectors for base64url encode/decode round-trip of canonical bytes.

Example reference flow:

```text
1) Build Envelope with body = h'68656c6c6f' ("hello") plus 32-byte to_wayfarer_id and manifest_id.
2) Canonically CBOR-encode Envelope to envelope_bytes.
3) Compute item_id = SHA256(envelope_bytes).
4) Encode envelope_b64 = base64url(envelope_bytes) with no padding.
5) Transmit in TRANSFER.objects[] with item_id and envelope_b64.
6) Receiver decodes base64url, re-hashes bytes, validates item_id, decodes CBOR, validates schema, then accepts object.
```

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

## Canonical Envelope Conformance Vectors

Canonical signed-envelope vectors are maintained in:

- `Fixtures/Protocol/gossip-v1/item_id_derivation.json`
- `tests/compatibility/vectors/envelope_vector_1.json`
- `tests/compatibility/vectors/envelope_vector_1.expected.json`

Implementations **MUST** pass vectors that cover at least:

1. valid signature acceptance,
2. invalid signature rejection,
3. mismatched `author_pubkey`/`author_sig` rejection,
4. deterministic `wayfarer_id = SHA-256(author_pubkey)` derivation,
5. relay-forwarded object verification with immutable envelope bytes.

## 6. Deterministic rejection/acceptance rules

1. Deduplication **MUST** be by `item_id` only.
2. Unknown frame `type` **MUST** be rejected.
3. Missing required fields **MUST** be rejected.
4. Invalid hash, malformed encoding, malformed base64url, or expired objects **MUST** be rejected.
5. Bearer metadata **MUST NOT** alter acceptance semantics.
6. Bearer peer identity metadata **MUST NOT** override canonical object authorship.

## 6.1 Status/error namespace reservation

String status/error code namespaces are reserved as follows:

- `AUTH_*`: authentication and identity failures
- `PROTO_*`: deterministic protocol/schema failures
- `TRANSIENT_*`: retryable transport/runtime faults

Implementations **MUST NOT** reinterpret unknown namespaces as successful outcomes.

## 7. Forwarding semantics anchor

When forwarding objects:

1. Envelope bytes **MUST NOT** be modified.
2. `hop_count` **MUST** increment by exactly 1.
3. Forwarders **MUST NOT** emit values causing overflow.
