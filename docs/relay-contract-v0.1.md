# RelayLink v0.1 Contract

Status: Historical/legacy reference. Canonical v1 client-relay contract is `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md`.

> WARNING (v0.1 vs v1 divergence):
> - In v1, `payload_b64` carries canonical `EnvelopeV1` bytes from `docs/protocol.md` (`Canonical Bytes v1`), not generic "CBOR bytes" wording.
> - In v1, idempotency uses `client_msg_id`; v0.1 wording about retrying with `msg_id` is legacy and not accurate for v1.

## Overview

RelayLink is a JSON-over-WebSocket protocol for cross-platform client-to-relay communication. It provides reliable message delivery with acknowledgment semantics and supports both push (server-initiated) and pull (client-initiated) delivery models.

## Identifiers

### WayfarerID

A WayfarerID is the SHA256 hash of an Ed25519 public key, represented as a lowercase hexadecimal string (64 characters).

```
wayfarer_id := hex_lower(sha256(ed25519_pubkey_raw_bytes))
            // exactly 64 lowercase hex chars: 0-9, a-f
```

Canonical v1 derivation is defined in `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md`.

Example (hex placeholder): `0123...abcd`

## Wire Format

All frames are JSON objects sent over WebSocket as text messages.

### Base64 Encoding

Payloads use strict base64url (RFC 4648, URL-safe alphabet) with no padding:
- Encoding: MUST emit unpadded base64url (`=` padding omitted)
- Decoding: MUST use strict base64url decode and fail fast on invalid input

### CBOR Wire Bytes

Note: The "CBOR-encoded" wording below is historical v0.1 terminology. v1 defines `payload_b64` as canonical `EnvelopeV1` bytes in `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md`.

The `payload_b64` field contains CBOR-encoded data. The internal structure follows the EnvelopeV1 schema:
- `toWayfarerId`: 32-byte recipient ID (Data)
- `manifestId`: 32-byte manifest reference (Data)  
- `body`: Application payload (Data)

## Message Types

### Client → Relay

#### hello

Client sends immediately after WebSocket connect to identify itself.

```json
{
  "type": "hello",
  "wayfarer_id": "0123...abcd"
}
```

#### send

Client sends a message to another Wayfarer via the relay.

```json
{
  "type": "send",
  "to": "0123...abcd",
  "payload_b64": "o2...",
  "ttl_seconds": 3600
}
```

- `to`: Recipient WayfarerID (64 hex chars)
- `payload_b64`: strict base64url (RFC 4648, no padding) encoded CBOR envelope bytes
- `ttl_seconds`: Message time-to-live (default: 3600)
- Returns `send_ok` with `msg_id` for acknowledgment

#### pull

Client requests pending messages from the relay.

```json
{
  "type": "pull",
  "limit": 50
}
```

- `limit`: Maximum messages to return (default: 50)

#### ack

Client acknowledges receipt of a message (triggers relay-side deletion).

```json
{
  "type": "ack",
  "msg_id": "uuid..."
}
```

### Relay → Client

#### hello_ok

Relay acknowledges successful client authentication/registration.

```json
{
  "type": "hello_ok",
  "relay_id": "relay-001"
}
```

#### send_ok

Relay acknowledges message acceptance for delivery.

```json
{
  "type": "send_ok",
  "msg_id": "uuid..."
}
```

#### message

Relay delivers a message to the client (push model).

```json
{
  "type": "message",
  "msg_id": "uuid...",
  "from": "0123...abcd",
  "payload_b64": "o2...",
  "received_at": 1234567890
}
```

#### messages

Relay responds to a pull request with multiple messages.

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

#### ack_ok

Relay acknowledges message deletion.

```json
{
  "type": "ack_ok",
  "msg_id": "uuid..."
}
```

#### error

Relay signals an error condition.

```json
{
  "type": "error",
  "code": "INVALID_PAYLOAD",
  "message": "Base64 decode failed"
}
```

## Connection Lifecycle

1. **Connect**: Client opens WebSocket to relay URL
2. **Hello**: Client sends `hello`, waits for `hello_ok`
3. **Ready**: After `hello_ok`, client can `send`, `pull`, `ack`
4. **Disconnect**: Connection closed (intentional or network failure)
5. **Reconnect**: Client reconnects, sends `hello` again

## Acknowledgment Semantics

### Send Acknowledgment

The relay MUST:
1. **Durably persist** the message
2. **Confirm ingest success** (valid payload, valid recipient)
3. Then send `send_ok`

The client MUST NOT consider a message delivered until `send_ok` is received. If no response within timeout, client should retry (with same `msg_id` for idempotency).

Note: v1 replaces this retry-idempotency wording with `client_msg_id`; see `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md`.

### Receive Acknowledgment

The relay delivers messages via `message` (push) or `messages` (pull). The client SHOULD send `ack` once the message is:
- Successfully processed (stored to disk, displayed to user, etc.)
- Not a duplicate

The relay MUST NOT delete a message until it has accepted the client's `ack` and sent `ack_ok`. This provides at-least-once delivery semantics.

## Retry & Reconnect Expectations

### Client Retry (Send)

- If `send_ok` not received within 30 seconds, retry with same `msg_id`
- Relay MUST handle duplicate `msg_id` gracefully (idempotent)
- After 3 retries, consider recipient offline or relay unavailable

Note: In v1, retries are keyed by `client_msg_id` rather than `msg_id`.

### Reconnection

- On disconnect, client should attempt reconnect with exponential backoff
- Base: 1s, Max: 60s, Jitter: ±20%
- After reconnect, client re-sends `hello`
- If `pull_on_connect` enabled, client pulls until empty

### Message Expiry

- Messages older than `ttl_seconds` may be deleted by relay
- Client should not retry sends beyond TTL

## Error Codes

| Code | Description |
|------|-------------|
| `INVALID_WAYFARER_ID` | Malformed or unknown wayfarer_id |
| `INVALID_PAYLOAD` | Base64 decode failed or CBOR parse error |
| `PAYLOAD_TOO_LARGE` | Exceeds max message size |
| `RECIPIENT_OFFLINE` | Recipient not reachable |
| `RATE_LIMITED` | Too many requests |
| `AUTH_FAILED` | Authentication/authorization failed |
| `INTERNAL_ERROR` | Relay internal error |

## Implementation Notes

- All JSON keys use snake_case (convertFromSnakeCase)
- Timestamps are Unix epoch seconds (Int64)
- Message IDs are UUIDs (v4)
- WebSocket reconnect uses URLSessionWebSocketTask
- All operations are async/await within Swift actors
