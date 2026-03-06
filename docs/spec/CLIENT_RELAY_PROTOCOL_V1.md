# CLIENT_RELAY_PROTOCOL_V1

Status: Canonical v1 contract (MVP0)

This document defines the normative client-relay wire protocol.

- Canonical contract source: `docs/spec/*` (see `docs/adr/ADR-0001-protocol-contract-source-of-truth.md`)
- Historical context: `docs/relay-contract-v0.1.md`
- Core canonical structures: `docs/protocol.md`

## 1. Transport and Encoding

1. Frames MUST be JSON objects sent as WebSocket text messages.
2. All keys MUST be snake_case.
3. `payload_b64` MUST use base64url (RFC 4648 URL-safe alphabet) with no padding.
4. `payload_b64` bytes MUST decode to canonical `EnvelopeV1` bytes encoded per `Canonical Bytes v1` in `docs/protocol.md`.

## 2. Shared Types

- `wayfarer_id`: string, lowercase hex, exactly 64 chars (`[0-9a-f]{64}`).
  - Canonical derivation: `wayfarer_id = hex_lower(SHA-256(ed25519_public_key_raw_bytes))`.
  - `ed25519_public_key_raw_bytes` means the 32-byte Ed25519 public key byte sequence (not hex/base64/text encoding).
- `device_id`: string, stable identifier unique per device for a given `wayfarer_id`.
  - RECOMMENDED derivation: `device_id = hex_lower(SHA-256(ed25519_device_public_key_raw_bytes))`.
  - `ed25519_device_public_key_raw_bytes` means the 32-byte Ed25519 device public key byte sequence (not hex/base64/text encoding).
  - Other stable opaque strings are allowed.
  - Relays MUST treat `device_id` as opaque.
- `msg_id`: string, opaque relay-assigned message identifier (UUID v4 RECOMMENDED).
- `client_msg_id`: string, client-provided idempotency key.
  - MUST be 1..128 ASCII characters (`0x21`..`0x7E`).
  - UUID v4 RECOMMENDED.
- `ttl_seconds`: integer (`Int64`) in seconds, positive, default `3600` when omitted.
- `received_at`: integer (`Int64`), Unix epoch seconds.
- `expires_at`: integer (`Int64`), Unix epoch seconds.
- `limit`: integer (`Int64`), positive, default `50` when omitted.

## 3. Frame Types

### 3.1 Client -> Relay

#### `hello` (REQUIRED first frame)

```json
{
  "type": "hello",
  "wayfarer_id": "0123...abcd",
  "device_id": "89ef...4567"
}
```

Required fields:

- `type`: string, must be `hello`
- `wayfarer_id`: `wayfarer_id`
- `device_id`: `device_id` (REQUIRED in v1)

#### `send`

```json
{
  "type": "send",
  "to": "0123...abcd",
  "payload_b64": "o2...",
  "client_msg_id": "550e8400-e29b-41d4-a716-446655440000",
  "ttl_seconds": 3600
}
```

Required fields:

- `type`: string, must be `send`
- `to`: `wayfarer_id`
- `payload_b64`: string, base64url canonical `EnvelopeV1` bytes

Optional fields:

- `client_msg_id`: `client_msg_id`
- `ttl_seconds`: `ttl_seconds` (seconds)

#### `pull`

```json
{
  "type": "pull",
  "limit": 50
}
```

Required fields:

- `type`: string, must be `pull`

Optional fields:

- `limit`: `limit`

#### `ack`

```json
{
  "type": "ack",
  "msg_id": "uuid..."
}
```

Required fields:

- `type`: string, must be `ack`
- `msg_id`: `msg_id`

### 3.2 Relay -> Client

#### `hello_ok`

```json
{
  "type": "hello_ok",
  "relay_id": "relay-001"
}
```

Required fields:

- `type`: string, must be `hello_ok`
- `relay_id`: string, opaque relay identifier

#### `send_ok`

```json
{
  "type": "send_ok",
  "msg_id": "uuid...",
  "received_at": 1234567890,
  "expires_at": 1234571490
}
```

Required fields:

- `type`: string, must be `send_ok`
- `msg_id`: `msg_id`

Optional fields:

- `received_at`: `received_at` (Unix epoch seconds)
- `expires_at`: `expires_at` (Unix epoch seconds)
- If either `received_at` or `expires_at` is present, relay MUST include both.

#### `message`

```json
{
  "type": "message",
  "msg_id": "uuid...",
  "from": "0123...abcd",
  "payload_b64": "o2...",
  "received_at": 1234567890
}
```

Required fields:

- `type`: string, must be `message`
- `msg_id`: `msg_id`
- `from`: `wayfarer_id`
- `payload_b64`: string, base64url canonical `EnvelopeV1` bytes
- `received_at`: `received_at` (Unix epoch seconds)

#### `messages`

```json
{
  "type": "messages",
  "messages": [
    {
      "msg_id": "uuid...",
      "from": "0123...abcd",
      "payload_b64": "o2...",
      "received_at": 1234567890
    }
  ]
}
```

Required fields:

- `type`: string, must be `messages`
- `messages`: array of message objects with required fields `msg_id`, `from`, `payload_b64`, `received_at` (`received_at` is Unix epoch seconds)

#### `ack_ok`

```json
{
  "type": "ack_ok",
  "msg_id": "uuid..."
}
```

`ack_ok` is the relay response frame to `ack`.

Required fields:

- `type`: string, must be `ack_ok`
- `msg_id`: `msg_id`

#### `error`

```json
{
  "type": "error",
  "code": "INVALID_PAYLOAD",
  "message": "Base64 decode failed"
}
```

Required fields:

- `type`: string, must be `error`
- `code`: string, one of:
  - `INVALID_WAYFARER_ID`
  - `TO_MISMATCH`
  - `INVALID_PAYLOAD`
  - `PAYLOAD_TOO_LARGE`
  - `RECIPIENT_OFFLINE`
  - `RATE_LIMITED`
  - `AUTH_FAILED`
  - `IDEMPOTENCY_MISMATCH`
  - `INTERNAL_ERROR`
- `message`: string, human-readable explanation

Code semantics note:

- `TO_MISMATCH`: `send.to` does not equal `hex_lower(EnvelopeV1.toWayfarerId)` decoded from `payload_b64`.

## 4. Security and Authentication

1. Deployments MUST authenticate each client connection and authorize that the authenticated peer is allowed to act as `hello.wayfarer_id`.
2. This specification does not standardize the authentication mechanism; deployments MAY use mTLS, bearer tokens, signed challenges, or equivalent mechanisms.
3. If authentication or authorization fails, relay MUST return `error(code=AUTH_FAILED, ...)` and MAY close the connection.
4. Deployments MUST prevent one authenticated peer from claiming arbitrary `device_id` values that affect per-device delivery or ack state.
5. Deployments MUST enforce this property by a binding mechanism defined by deployment policy, for example:
   - deriving `device_id` from authenticated device key material, or
   - verifying the claimed `device_id` is registered to the authenticated `wayfarer_id`.

## 5. Ordering and Connection Rules

1. Client MUST send `hello` immediately after WebSocket connect.
2. Client MUST wait for `hello_ok` before sending `send`, `pull`, or `ack`.
3. Relay MUST reject non-`hello` frames before successful handshake (typically via `error`, then close).

## 6. Delivery, Ack, and Per-Device Semantics

### 6.1 Send acceptance

Relay MUST:

1. Decode `payload_b64` as canonical `EnvelopeV1` bytes encoded per `Canonical Bytes v1` in `docs/protocol.md`.
2. Let `toWayfarerId_bytes` be the decoded `EnvelopeV1.toWayfarerId` raw bytes.
3. Enforce `send.to == hex_lower(toWayfarerId_bytes)`.
4. If step 3 fails, relay MUST reject and MUST return `error(code=TO_MISMATCH, ...)`.
5. Validate sender authorization (per Section 4), recipient, and payload semantics.
6. Durably persist message state, including immutable `received_at` and `expires_at` timestamps.
7. Only then emit `send_ok`.

Client MUST treat send as unconfirmed until `send_ok` arrives.

### 6.2 Retry and idempotency

1. If no `send_ok` within 30 seconds, client SHOULD retry `send`.
2. `client_msg_id` is OPTIONAL for backward compatibility with `docs/relay-contract-v0.1.md`.
3. If client sets `client_msg_id`, it MUST reuse the same value for retries of that same logical send.
4. If `client_msg_id` is present, relay MUST dedupe by `(sender_wayfarer_id, client_msg_id)` where `sender_wayfarer_id` is the authenticated `hello.wayfarer_id`.
5. For that dedupe key, the first accepted `send` establishes an idempotency tuple of:
   - `to`
   - decoded `payload_b64` bytes
   - requested `ttl_seconds` value (with omitted value treated as `3600`)
6. For subsequent `send` frames with the same `(sender_wayfarer_id, client_msg_id)`:
   - If the idempotency tuple matches exactly, relay MUST return the same `send_ok` values (`msg_id`, `received_at`, `expires_at`) as the original accepted send.
   - If the idempotency tuple differs, relay MUST NOT create a new message and MUST respond with `error(code=IDEMPOTENCY_MISMATCH, ...)`.
7. If `client_msg_id` is absent, idempotency is best-effort and not guaranteed.
8. Client SHOULD treat the relay as unavailable/offline after 3 retries.

Backoff guidance: exponential backoff, base 1s, max 60s, jitter +/-20%.

### 6.3 Per-device tracking and ack binding (v1 requirement)

Delivery and ack state MUST be tracked by `(wayfarer_id, device_id)`.

Per-device ack binding in this section relies on the `device_id` authenticity/binding requirement in Section 4.

- Relay MUST maintain per-device pending state keyed by `(wayfarer_id, device_id, msg_id)`.
- Relay MUST bind `ack(msg_id)` to the `(wayfarer_id, device_id)` established by `hello` on that connection.
- An `ack` from one device MUST NOT suppress delivery to other devices under the same `wayfarer_id`.
- Relay MAY remove message data only when no per-device pending records remain, or when message TTL expires.
- Relay MAY allow concurrent connections that present the same `(wayfarer_id, device_id)`; if allowed, those connections are equivalent for ack binding. Relay MAY instead reject additional concurrent connections by deployment policy.

### 6.4 Receive acknowledgment

- Relay delivers via `message` (push) and/or `messages` (pull).
- Client SHOULD send `ack` only after message is processed and determined non-duplicate for that device.
- Relay MUST NOT consider the device-specific delivery complete until it receives `ack` and durably persists that per-device state transition.
- `ack_ok` confirms relay acceptance of that `ack`; it is not the completion condition itself.

This yields at-least-once delivery per `(wayfarer_id, device_id)`.

## 7. TTL Semantics (Normative)

1. `ttl_seconds` is measured in seconds; default requested TTL is `3600`.
2. Relay MAY enforce a maximum TTL via `MAX_TTL_SECONDS` (implementation-defined).
3. `effective_ttl_seconds = min(requested_ttl_seconds, MAX_TTL_SECONDS)` when max is enforced; otherwise `effective_ttl_seconds = requested_ttl_seconds`.
4. On durable send acceptance, relay MUST set `received_at` to current Unix epoch seconds and MUST persist immutable `expires_at = received_at + effective_ttl_seconds`.
5. `expires_at` is immutable for that `msg_id`; retries, reconnects, pull/push redelivery, and relay internal retries MUST NOT extend it.
6. Expired messages (`now_seconds >= expires_at`) MUST NOT be delivered.
7. Clients SHOULD NOT retry sends beyond message TTL.

## 8. Minimal Sequences

### 8.1 Happy path

1. Client connects WS.
2. Client -> Relay: `hello(wayfarer_id, device_id)`.
3. Relay -> Client: `hello_ok`.
4. Client -> Relay: `send(to, payload_b64, client_msg_id?, ttl_seconds)`.
5. Relay durably persists.
6. Relay -> Client: `send_ok(msg_id, received_at?, expires_at?)`.
7. Recipient device receives `message(msg_id, ...)` (push) or via `messages` after `pull`.
8. Recipient device -> Relay: `ack(msg_id)`.
9. Relay -> Recipient device: `ack_ok(msg_id)`.

### 8.2 Reconnect and idempotent resend

1. Sender sends `send`, connection drops before `send_ok`.
2. Sender reconnects, performs `hello`/`hello_ok`.
3. Sender retries same logical `send` within 30s timeout policy, reusing `client_msg_id` when present.
4. Relay deduplicates and returns the same `msg_id`, `received_at`, and `expires_at` in `send_ok` when `client_msg_id` is present.
5. Duplicate recipient delivery for that same `(wayfarer_id, device_id, msg_id)` MUST NOT be created.
