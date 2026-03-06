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
4. `payload_b64` bytes MUST decode to CBOR bytes containing the core envelope payload (see `docs/protocol.md`).

## 2. Shared Types

- `wayfarer_id`: string, lowercase hex, exactly 64 chars (`[0-9a-f]{64}`), SHA-256 of Ed25519 public key.
- `device_id`: string, stable identifier unique per device for a given `wayfarer_id`.
  - RECOMMENDED format: lowercase hex SHA-256 of the device Ed25519 public key (64 chars).
  - Other stable opaque strings are allowed.
  - Relays MUST treat `device_id` as opaque.
- `msg_id`: string, opaque relay-assigned message identifier (UUID v4 RECOMMENDED).
- `ttl_seconds`: integer (`Int64`), positive, default `3600` when omitted.
- `received_at`: integer (`Int64`), Unix epoch seconds.
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
  "ttl_seconds": 3600
}
```

Required fields:

- `type`: string, must be `send`
- `to`: `wayfarer_id`
- `payload_b64`: string, base64url CBOR bytes

Optional fields:

- `ttl_seconds`: `ttl_seconds`

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
  "msg_id": "uuid..."
}
```

Required fields:

- `type`: string, must be `send_ok`
- `msg_id`: `msg_id`

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
- `payload_b64`: string, base64url CBOR bytes
- `received_at`: `received_at`

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
- `messages`: array of message objects with required fields `msg_id`, `from`, `payload_b64`, `received_at`

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
  - `INVALID_PAYLOAD`
  - `PAYLOAD_TOO_LARGE`
  - `RECIPIENT_OFFLINE`
  - `RATE_LIMITED`
  - `AUTH_FAILED`
  - `INTERNAL_ERROR`
- `message`: string, human-readable explanation

## 4. Ordering and Connection Rules

1. Client MUST send `hello` immediately after WebSocket connect.
2. Client MUST wait for `hello_ok` before sending `send`, `pull`, or `ack`.
3. Relay MUST reject non-`hello` frames before successful handshake (typically via `error`, then close).

## 5. Delivery, Ack, and Per-Device Semantics

### 5.1 Send acceptance

Relay MUST:

1. Validate sender, recipient, and payload.
2. Durably persist message state.
3. Only then emit `send_ok`.

Client MUST treat send as unconfirmed until `send_ok` arrives.

### 5.2 Retry and idempotency

1. If no `send_ok` within 30 seconds, client SHOULD retry `send`.
2. Relay MUST handle duplicate sends idempotently and return a stable `msg_id` for the same logical message.
3. Client SHOULD treat the relay as unavailable/offline after 3 retries.

Backoff guidance: exponential backoff, base 1s, max 60s, jitter +/-20%.

### 5.3 Per-device tracking (v1 requirement)

Delivery and ack state MUST be tracked by `(wayfarer_id, device_id)`.

- Relay MUST maintain per-device pending state keyed by `(wayfarer_id, device_id, msg_id)`.
- An `ack` from one device MUST NOT suppress delivery to other devices under the same `wayfarer_id`.
- Relay MAY remove message data only when no per-device pending records remain, or when message TTL expires.

### 5.4 Receive acknowledgment

- Relay delivers via `message` (push) and/or `messages` (pull).
- Client SHOULD send `ack` only after message is processed and determined non-duplicate for that device.
- Relay MUST NOT consider the device-specific delivery complete until `ack_ok` for that device.

This yields at-least-once delivery per `(wayfarer_id, device_id)`.

## 6. TTL Semantics (Normative)

1. `ttl_seconds` default is `3600`.
2. Relay MAY enforce a maximum TTL (`MAX_TTL_SECONDS`, implementation-defined).
3. Effective TTL is `min(requested_or_default_ttl, MAX_TTL_SECONDS)` when max is enforced.
4. Expired messages MUST NOT be delivered.
5. TTL MUST NOT be extended by relay forwarding, retries, redelivery, or reconnect behavior.
6. Clients SHOULD NOT retry sends beyond message TTL.

## 7. Minimal Sequences

### 7.1 Happy path

1. Client connects WS.
2. Client -> Relay: `hello(wayfarer_id, device_id)`.
3. Relay -> Client: `hello_ok`.
4. Client -> Relay: `send(to, payload_b64, ttl_seconds)`.
5. Relay durably persists.
6. Relay -> Client: `send_ok(msg_id)`.
7. Recipient device receives `message(msg_id, ...)` (push) or via `messages` after `pull`.
8. Recipient device -> Relay: `ack(msg_id)`.
9. Relay -> Recipient device: `ack_ok(msg_id)`.

### 7.2 Reconnect and idempotent resend

1. Sender sends `send`, connection drops before `send_ok`.
2. Sender reconnects, performs `hello`/`hello_ok`.
3. Sender retries same logical `send` within 30s timeout policy.
4. Relay deduplicates and returns the same `msg_id` in `send_ok`.
5. Duplicate recipient delivery for that same `(wayfarer_id, device_id, msg_id)` MUST NOT be created.
