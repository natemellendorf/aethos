# FEDERATION_PROTOCOL_V1

Status: Canonical v1 contract (relay-relay federation)

This document defines the relay-to-relay protocol contract for forwarding envelopes across relay boundaries.

- Canonical contract source: `docs/spec/*` (see `docs/adr/ADR-0001-protocol-contract-source-of-truth.md`)
- Canonical transport-neutral envelope semantics: `docs/protocol/frames.md` (§5.4.1)

## 1. Transport and Encoding

Transport encoding is not finalized.

- Logical field names, types, and invariants in this document are normative.
- CBOR is the preferred transport for v1 alignment with core protocol.
- JSON transport MAY be used during transition/debugging if it preserves the same field semantics.

All timestamp fields in this document use Unix epoch milliseconds encoded as `UInt64` (`created_at`, `expires_at`, `sent_at`).
Guard rail: unlike `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md` (`received_at`/`expires_at` in seconds), federation timestamp fields are milliseconds.

## 2. Envelope Schema (Normative)

Federation forwarding uses this envelope object:

- `envelope_id`: bytes(32) identifier derived as `SHA-256(payload)` (JSON form: 64-char lowercase hex string)
- `destination`: bytes(32) WayfarerID destination (logical type is always 32 raw bytes)
- `payload`: bytes canonical envelope bytes consistent with `docs/protocol/frames.md` (§5.4.1) (JSON form: base64url string, no padding)
- `created_at`: `UInt64` Unix ms
- `expires_at`: `UInt64` Unix ms
- `hop_count`: `UInt16`
- `seen_relays`: array of relay identifiers (strings)

Derivation rules:

1. `payload` MUST be exactly canonical encoded envelope bytes.
2. `envelope_id` MUST be the SHA-256 digest of those exact `payload` bytes (`envelope_id = SHA-256(payload)`).
   This is the same derivation as Gossip V1 `item_id` (SHA-256 of canonical gossip envelope bytes).
3. `payload` bytes MUST decode to the canonical envelope map; `to_wayfarer_id` MUST be exactly 32 raw bytes.
4. Let `destination_bytes` be the logical destination value and `to_wayfarer_id_bytes` be decoded from envelope payload; `destination_bytes` MUST equal `to_wayfarer_id_bytes`.

Representation rules:

- JSON transports: `destination` MUST be represented as exactly 64 lowercase hex characters and MUST equal `hex_lower(to_wayfarer_id_bytes)`.
- CBOR/bytes transports: `destination` MUST be represented as raw 32 bytes.

## 3. Frame Types

### `relay_hello`

Session handshake and capability advertisement.

Required fields:

- `type`: `relay_hello`
- `relay_id`: string, stable relay identifier
- `protocol_version`: integer, must be `1`

Optional fields:

- `capabilities`: array of strings

### `relay_forward`

Forward a single federation envelope.

Required fields:

- `type`: `relay_forward`
- `envelope`: object with required fields:
  - `envelope_id`
  - `destination`
  - `payload`
  - `created_at`
  - `expires_at`
  - `hop_count`
  - `seen_relays`

### `relay_ack`

Acknowledge `relay_forward` accept/reject result.

Required fields:

- `type`: `relay_ack`
- `envelope_id`: same identifier as forwarded envelope
- `status`: string, one of `accepted`, `rejected`

Optional fields:

- `code`: string rejection code; REQUIRED when `status = rejected`, MAY be omitted when `status = accepted`
- `message`: string human-readable reason

### `relay_cover`

Cover traffic / keepalive frame. Does not represent business payload forwarding.

Required fields:

- `type`: `relay_cover`
- `relay_id`: sender relay identifier
- `sent_at`: `UInt64` Unix ms

Optional fields:

- `padding`: bytes (JSON form: base64url) to normalize traffic shape

## 4. Invariants and Validation Rules

1. Relays MUST enforce `MAX_HOPS` (implementation-defined constant).
2. Relay MUST reject forwarding when incoming `hop_count >= MAX_HOPS`.
3. For accepted envelopes (`hop_count < MAX_HOPS`), relay MUST increment `hop_count` by exactly 1 before forwarding onward.
4. `seen_relays` MUST include the local relay identifier before forwarding.
5. If local relay ID already exists in `seen_relays`, relay MUST reject to prevent loops.
6. `expires_at` is immutable after creation; TTL MUST NOT be extended at any relay hop.
7. Expired envelopes (`now_ms >= expires_at`) MUST NOT be forwarded.
8. If `envelope_id != SHA-256(payload)`, relay MUST reject, MUST NOT forward, and MUST send `relay_ack(status=rejected, code=ENVELOPE_ID_MISMATCH)`.
9. If logical `destination_bytes != to_wayfarer_id_bytes` decoded from `payload`, relay MUST reject, MUST NOT forward, and MUST send `relay_ack(status=rejected, code=DESTINATION_MISMATCH)`.

## 5. Minimal Forwarding Sequence

1. Relay A connects to Relay B.
2. Relay A -> Relay B: `relay_hello`.
3. Relay B -> Relay A: `relay_hello` (or equivalent successful handshake acceptance).
4. Relay A prepares envelope:
   - verifies `hop_count < MAX_HOPS` before any forward attempt
   - increments `hop_count`
   - appends `relay-a` to `seen_relays`
5. Relay A -> Relay B: `relay_forward(envelope)`.
6. Relay B validates invariants and expiry.
7. Relay B -> Relay A: `relay_ack(envelope_id, status=accepted)`.

## 6. Rejection Cases (Minimum)

Relay MUST return `relay_ack(status=rejected, code=...)` when any of the following holds:

- `EXPIRED`: `expires_at` already passed
- `HOP_LIMIT_EXCEEDED`: `hop_count` violates `MAX_HOPS`
- `LOOP_DETECTED`: local relay already present in `seen_relays`
- `INVALID_DESTINATION`: malformed `destination`
- `INVALID_PAYLOAD`: malformed/undecodable payload bytes
- `ENVELOPE_ID_MISMATCH`: `envelope_id` does not equal `SHA-256(payload)`
- `DESTINATION_MISMATCH`: logical `destination_bytes` does not match `to_wayfarer_id_bytes` decoded from `payload`
