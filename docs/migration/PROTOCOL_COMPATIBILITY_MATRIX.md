# Protocol Compatibility Matrix (Migration Scoreboard)

Purpose: track implementation alignment against canonical protocol specs across `aethos-relay` and `aethos-ios`, and map each gap to migration work. Related migration plan: `docs/migration/protocol_update.md`.

## Progress Summary

- Total Features: 33
- Aligned With Spec: 1
- Diverging From Spec: 25
- Verification Needed: 7

Counts are computed per row: **Aligned** when both Relay and iOS are `OK`; **Diverging** when either side is `DIVERGES`; **Verification Needed** when no side is `DIVERGES` and at least one side is `VERIFY` or `NOT_IMPLEMENTED`.

## Schema

| Feature ID | Feature | Spec Expectation | Relay Status | iOS Status | Owner | Migration Status | Alignment Bead | Spec Reference |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |

Status vocab:

- Relay/iOS Status: `OK` / `DIVERGES` / `VERIFY` / `NOT_IMPLEMENTED`
- Migration Status: `TODO` / `IN_PROGRESS` / `COMPLETE`
- Owner: `aethos-relay` / `aethos-ios` / `both`

## Client Relay Protocol

| Feature ID | Feature | Spec Expectation | Relay Status | iOS Status | Owner | Migration Status | Alignment Bead | Spec Reference |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| CRP-HELLO-DEVICE-ID | `hello.device_id` required | `hello` must include `wayfarer_id` + `device_id` in v1. | DIVERGES | DIVERGES | both | TODO | - | `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md` - `3.1 hello` |
| CRP-HELLO-WAYFARER-ID-FORMAT | `wayfarer_id` format validation | `wayfarer_id` must be lowercase 64-char hex (`[0-9a-f]{64}`). | DIVERGES | VERIFY | aethos-relay | TODO | - | `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md` - `2. Shared Types` |
| CRP-HELLO-OK-RELAY-ID | `hello_ok.relay_id` required | `hello_ok` must include `relay_id`. | DIVERGES | VERIFY | aethos-relay | TODO | - | `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md` - `3.2 hello_ok` |
| CRP-PAYLOAD-BASE64URL | `payload_b64` canonical encoding | `payload_b64` must be unpadded base64url canonical `EnvelopeV1` bytes. | DIVERGES | DIVERGES | both | TODO | - | `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md` - `1. Transport and Encoding` |
| CRP-SEND-TO-MISMATCH-INVARIANTS | Canonical send acceptance invariants | Relay must decode canonical envelope bytes and reject `send.to` mismatches with `TO_MISMATCH`. | DIVERGES | VERIFY | aethos-relay | TODO | - | `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md` - `6.1 Send acceptance` |
| CRP-HANDSHAKE-ORDERING | Handshake gating before other frames | Client must wait for `hello_ok`; relay must reject pre-handshake non-`hello` frames. | VERIFY | VERIFY | both | TODO | - | `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md` - `5. Ordering and Connection Rules` |
| CRP-ACK-FRAME-SHAPE | Transport ack frame shape | `ack(msg_id)` and `ack_ok(msg_id)` frame fields follow v1 contract. | OK | OK | both | COMPLETE | - | `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md` - `3.1 ack` / `3.2 ack_ok` |

## Delivery Semantics

| Feature ID | Feature | Spec Expectation | Relay Status | iOS Status | Owner | Migration Status | Alignment Bead | Spec Reference |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| DELIV-TIMESTAMP-FIELD-MAPPING | `at` vs `received_at` / `expires_at` | `message`/`messages` use `received_at`; `send_ok` uses optional paired `received_at` + `expires_at`. | DIVERGES | DIVERGES | both | TODO | - | `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md` - `3.2 send_ok`, `3.2 message`, `3.2 messages` |
| DELIV-PER-DEVICE-ACK-BINDING | Per-device delivery keying | Delivery/ack must bind to `(wayfarer_id, device_id, msg_id)` and not cross-suppress devices. | DIVERGES | VERIFY | both | TODO | - | `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md` - `6.3 Per-device tracking and ack binding` |
| DELIV-IDEMPOTENCY-CLIENT-MSG-ID | Idempotent resend support | When `client_msg_id` is present, relay must dedupe and enforce tuple invariants. | DIVERGES | VERIFY | aethos-relay | TODO | - | `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md` - `6.2 Retry and idempotency` |
| DELIV-TTL-DEFAULT-3600 | Default TTL semantics | Omitted `ttl_seconds` defaults to `3600` before max-TTL capping logic. | DIVERGES | VERIFY | aethos-relay | TODO | - | `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md` - `2. Shared Types`, `7. TTL Semantics` |
| DELIV-EXPIRED-DELIVERY-BOUNDARY | Expired messages must not deliver | Messages with `now_seconds >= expires_at` must not be delivered. | DIVERGES | VERIFY | aethos-relay | TODO | - | `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md` - `7. TTL Semantics` |
| DELIV-ACK-OK-ROUNDTRIP | `ack_ok` await/validation behavior | `ack_ok` confirms accepted ack; client flow should treat it as the ack response boundary. | OK | DIVERGES | aethos-ios | TODO | - | `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md` - `6.4 Receive acknowledgment` |
| DELIV-RETRY-POLICY | Retry/backoff policy conformance | Retry window/backoff guidance: 30s timeout, bounded retries, jittered backoff. | VERIFY | VERIFY | both | TODO | - | `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md` - `6.2 Retry and idempotency` |

## Message Retrieval

| Feature ID | Feature | Spec Expectation | Relay Status | iOS Status | Owner | Migration Status | Alignment Bead | Spec Reference |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| RETR-PULL-MESSAGES-FIELD-SHAPE | Pull response item schema | `messages[]` entries must include canonical `msg_id`, `from`, `payload_b64`, `received_at` fields. | DIVERGES | DIVERGES | both | TODO | - | `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md` - `3.2 messages` |
| RETR-MESSAGES-STRICT-PARSING | Strict required-shape handling | `messages` frame should enforce required array/object shape instead of silently accepting malformed structures. | VERIFY | DIVERGES | aethos-ios | TODO | - | `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md` - `3.2 messages` |
| RETR-PULL-LIMIT-DEFAULT | Pull limit default behavior | Omitted `pull.limit` defaults to `50`. | OK | VERIFY | both | TODO | - | `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md` - `2. Shared Types`, `3.1 pull` |

## Error Handling

| Feature ID | Feature | Spec Expectation | Relay Status | iOS Status | Owner | Migration Status | Alignment Bead | Spec Reference |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| ERR-ERROR-FRAME-SCHEMA | Structured error payload schema | `error` must include `code` and `message` fields. | DIVERGES | DIVERGES | both | TODO | - | `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md` - `3.2 error` |
| ERR-ERROR-CODE-VOCABULARY | Canonical error code set semantics | Error codes should map to canonical vocabulary (for example `TO_MISMATCH`, `INVALID_PAYLOAD`, `AUTH_FAILED`). | DIVERGES | VERIFY | aethos-relay | TODO | - | `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md` - `3.2 error` |
| ERR-PRE-HELLO-ERROR-PATH | Pre-handshake rejection behavior | Relay should reject non-`hello` pre-handshake frames via canonical error path. | VERIFY | VERIFY | both | TODO | - | `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md` - `5. Ordering and Connection Rules` |

## Federation Protocol

| Feature ID | Feature | Spec Expectation | Relay Status | iOS Status | Owner | Migration Status | Alignment Bead | Spec Reference |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| FED-WIRE-MODEL-ENVELOPE-FORWARD | Canonical federation wire model | Federation should use `relay_forward(envelope)` + canonical `relay_ack`/`relay_cover` model. | DIVERGES | NOT_IMPLEMENTED | aethos-relay | TODO | - | `docs/spec/FEDERATION_PROTOCOL_V1.md` - `3. Frame Types` |
| FED-HELLO-PROTOCOL-VERSION | `relay_hello.protocol_version` contract | `relay_hello` must carry integer `protocol_version = 1`. | DIVERGES | NOT_IMPLEMENTED | aethos-relay | TODO | - | `docs/spec/FEDERATION_PROTOCOL_V1.md` - `3. relay_hello` |
| FED-RELAY-ACK-STATUS-MODEL | Relay ack status and reject payload | `relay_ack.status` must be `accepted|rejected`; rejections require canonical code/message semantics. | DIVERGES | NOT_IMPLEMENTED | aethos-relay | TODO | - | `docs/spec/FEDERATION_PROTOCOL_V1.md` - `3. relay_ack`, `6. Rejection Cases` |
| FED-HOP-LIMIT-ENFORCEMENT | Hop limit checks and increment | Relay must reject `hop_count >= MAX_HOPS` and increment by 1 before forwarding. | DIVERGES | NOT_IMPLEMENTED | aethos-relay | TODO | - | `docs/spec/FEDERATION_PROTOCOL_V1.md` - `4. Invariants and Validation Rules` |
| FED-SEEN-RELAYS-LOOP-PREVENTION | Loop prevention via `seen_relays` | Relay must append local relay, and reject if local relay already appears in `seen_relays`. | DIVERGES | NOT_IMPLEMENTED | aethos-relay | TODO | - | `docs/spec/FEDERATION_PROTOCOL_V1.md` - `4. Invariants and Validation Rules` |
| FED-DESTINATION-HASH-INVARIANTS | Destination + envelope hash invariants | Relay must enforce `envelope_id = SHA-256(payload)` and `destination == toWayfarerId` decoded from payload. | DIVERGES | NOT_IMPLEMENTED | aethos-relay | TODO | - | `docs/spec/FEDERATION_PROTOCOL_V1.md` - `2. Envelope Schema`, `4. Invariants and Validation Rules` |
| FED-EXPIRY-BOUNDARY | Expiry comparison boundary | Expired envelopes must be rejected when `now_ms >= expires_at`. | DIVERGES | NOT_IMPLEMENTED | aethos-relay | TODO | - | `docs/spec/FEDERATION_PROTOCOL_V1.md` - `4. Invariants and Validation Rules` |
| FED-TTL-NON-EXTENSION | `expires_at` immutability across hops | `expires_at` is immutable after creation; relays must not extend TTL across hops. | VERIFY | NOT_IMPLEMENTED | aethos-relay | TODO | - | `docs/spec/FEDERATION_PROTOCOL_V1.md` - `4. Invariants and Validation Rules` |
| FED-RELAY-COVER-SCHEMA | `relay_cover` field set and units | `relay_cover` should include `relay_id` and `sent_at` (Unix ms), with optional padding. | DIVERGES | NOT_IMPLEMENTED | aethos-relay | TODO | - | `docs/spec/FEDERATION_PROTOCOL_V1.md` - `3. relay_cover` |

## Receipt Semantics

| Feature ID | Feature | Spec Expectation | Relay Status | iOS Status | Owner | Migration Status | Alignment Bead | Spec Reference |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| RCP-RECEIPT-WRAPPER-SUPPORT | Receipt wrapper support for mixed scopes | JSON channels carrying mixed scopes require `receipt_scope` + `receipt_v1_b64` wrapper. | DIVERGES | VERIFY | both | TODO | - | `docs/spec/RECEIPTS.md` - `4.1 JSON transport wrapper` |
| RCP-NON-CONFLATION | Device vs federation non-conflation | `DeviceReceipt` and `FederationReceipt` semantics must remain distinct. | OK | VERIFY | both | TODO | - | `docs/spec/RECEIPTS.md` - `3. Non-Conflation Requirement` |
| RCP-ACK-TRANSPORT-VS-RECEIPT | `ack_ok` transport vs receipt semantics | `ack_ok` transport response semantics must remain separate from `ReceiptV1` semantics. | OK | VERIFY | both | TODO | - | `docs/spec/RECEIPTS.md` - `3. Non-Conflation Requirement`; `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md` - `3.2 ack_ok` |
| RCP-IOS-STATUS-VOCABULARY-MAPPING | Client status vocabulary mapping | Client-facing receipt/delivery vocabulary should align with canonical device-level receipt semantics. | VERIFY | DIVERGES | aethos-ios | TODO | - | `docs/spec/RECEIPTS.md` - `2. Vocabulary Layer`; `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md` - `6.3` / `6.4` |

## Updating the Matrix

- Keep `Feature ID` stable once introduced; never repurpose an ID for a different semantic.
- Never delete rows; retain history and update status fields as implementation evolves.
- Update Relay/iOS status directly from implementation audits, not inferred assumptions.
- Add the owning migration bead ID in `Alignment Bead` when work is scheduled or in progress.

## Sources

- iOS divergence audit: `/Users/natemellendorf/opencode/aethos-ios/docs/PROTOCOL_DIVERGENCES.md`
- Relay divergence audit: `/Users/natemellendorf/opencode/aethos-relay/.worktrees/protocol-divergence-audit/docs/PROTOCOL_DIVERGENCES.md`
- Canonical client-relay spec: `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md`
- Canonical federation spec: `docs/spec/FEDERATION_PROTOCOL_V1.md`
- Canonical receipt spec: `docs/spec/RECEIPTS.md`
- Migration plan: `docs/migration/protocol_update.md`
