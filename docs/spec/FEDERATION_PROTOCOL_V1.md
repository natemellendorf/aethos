# FEDERATION_PROTOCOL_V1

Status: Canonical v1 contract (relay-relay federation)

This document defines the relay-to-relay protocol contract for forwarding envelopes across relay boundaries.

- Canonical contract source: `docs/spec/*` (see `docs/adr/ADR-0001-protocol-contract-source-of-truth.md`)
- Core canonical structures and timestamp conventions: `docs/protocol.md`

## 1. Transport and Encoding

Transport encoding is not finalized.

- Logical field names, types, and invariants in this document are normative.
- CBOR is the preferred transport for v1 alignment with core protocol.
- JSON transport MAY be used during transition/debugging if it preserves the same field semantics.

All timestamp fields in this document use Unix epoch milliseconds encoded as `UInt64` (`created_at`, `expires_at`, `sent_at`).

## 2. Envelope Schema (Normative)

Federation forwarding uses this envelope object:

- `envelope_id`: bytes(32) identifier derived as `SHA-256(payload)` (JSON form: 64-char lowercase hex string)
- `destination`: bytes(32) WayfarerID destination (JSON form: 64-char lowercase hex string)
- `payload`: bytes canonical `EnvelopeV1` bytes as defined by `Canonical Bytes v1` in `docs/protocol.md` (JSON form: base64url string, no padding)
- `created_at`: `UInt64` Unix ms
- `expires_at`: `UInt64` Unix ms
- `hop_count`: `UInt32`
- `seen_relays`: array of relay identifiers (strings)

Derivation rules:

1. `payload` MUST be exactly the canonical encoded `EnvelopeV1` bytes.
2. `envelope_id` MUST be the SHA-256 digest of those exact `payload` bytes (`envelope_id = SHA-256(payload)`).
3. `payload` bytes MUST decode to `EnvelopeV1` per `Canonical Bytes v1` in `docs/protocol.md`; `EnvelopeV1.toWayfarerId` MUST be exactly 32 raw bytes.
4. `destination` MUST equal `hex_lower(EnvelopeV1.toWayfarerId)` where `destination` is represented on the wire as 64 lowercase hex characters.

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

- `code`: string rejection code
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
8. If `destination != hex_lower(EnvelopeV1.toWayfarerId)`, relay MUST reject, MUST NOT forward, and MUST send `relay_ack(status=rejected, code=DESTINATION_MISMATCH)`.

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
- `DESTINATION_MISMATCH`: `destination` does not match `hex_lower(EnvelopeV1.toWayfarerId)` decoded from `payload`
