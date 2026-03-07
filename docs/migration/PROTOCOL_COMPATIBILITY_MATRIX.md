# Protocol Compatibility Matrix (Migration Scoreboard)

Purpose: track implementation alignment against canonical protocol specs across `aethos-relay` and `aethos-ios`, and map each gap to migration work. Related migration plan: `docs/migration/protocol_update.md`.

## Progress Summary

- Total Features: 33
- Aligned With Spec: 1
- Diverging From Spec: 17
- Verification Needed: 6

Counts are computed per row: **Aligned** when both Relay and iOS are `OK`; **Diverging** when either side is `DIVERGES`; **Verification Needed** when no side is `DIVERGES` and at least one side is `VERIFY`. Rows with any `NOT_IMPLEMENTED` status are included in **Total Features** but excluded from **Aligned**/**Diverging**/**Verification Needed** totals.

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
| CRP-HELLO-DEVICE-ID | `hello.device_id` required (CRP-001) | `hello` must include `wayfarer_id` + `device_id` in v1. | DIVERGES | DIVERGES | both | TODO | - | Spec: `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#31-hello`; Audit: `relay#confirmed-divergences` / `ios#confirmed-divergences`; Rollout (CRP-001): canonical `hello` includes `wayfarer_id` + `device_id`; relay accepts both legacy and canonical `hello` during migration; iOS may send canonical `hello` before relay strictly requires it; strict enforcement is deferred until coordinated cutover; mark row `COMPLETE` only after both sides land and the legacy acceptance plan is explicitly documented. |
| CRP-HELLO-WAYFARER-ID-FORMAT | `wayfarer_id` format validation | `wayfarer_id` must be lowercase 64-char hex (`[0-9a-f]{64}`). | DIVERGES | VERIFY | aethos-relay | TODO | - | Spec: `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#2-shared-types`; Audit: `relay#confirmed-divergences` |
| CRP-HELLO-OK-RELAY-ID | `hello_ok.relay_id` required | `hello_ok` must include `relay_id`. | DIVERGES | VERIFY | aethos-relay | TODO | - | Spec: `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#32-hello_ok`; Audit: `relay#confirmed-divergences` |
| CRP-PAYLOAD-BASE64URL | `payload_b64` canonical encoding | `payload_b64` must be unpadded base64url canonical `EnvelopeV1` bytes. | DIVERGES | DIVERGES | both | TODO | - | Spec: `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#1-transport-and-encoding`; Audit: `relay#confirmed-divergences` / `ios#confirmed-divergences` |
| CRP-SEND-TO-MISMATCH-INVARIANTS | Canonical send acceptance invariants | Relay must decode canonical envelope bytes and reject `send.to` mismatches with `TO_MISMATCH`. | DIVERGES | VERIFY | aethos-relay | TODO | - | Spec: `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#61-send-acceptance`; Audit: `relay#confirmed-divergences` |
| CRP-HANDSHAKE-ORDERING | Handshake gating before other frames | Client must wait for `hello_ok`; relay must reject pre-handshake non-`hello` frames. | VERIFY | VERIFY | both | TODO | - | Spec: `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#5-ordering-and-connection-rules`; Audit: `ios#confirmed-matches` |
| CRP-ACK-FRAME-SHAPE | Transport ack frame shape | `ack(msg_id)` and `ack_ok(msg_id)` frame fields follow v1 contract. | OK | OK | both | COMPLETE | - | Spec: `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#31-ack`, `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#32-ack_ok`; Audit: `relay#confirmed-matches` / `ios#confirmed-matches` |

## Delivery Semantics

| Feature ID | Feature | Spec Expectation | Relay Status | iOS Status | Owner | Migration Status | Alignment Bead | Spec Reference |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| DELIV-TIMESTAMP-FIELD-MAPPING | `at` vs `received_at` / `expires_at` | `message`/`messages` use `received_at`; `send_ok` uses optional paired `received_at` + `expires_at`. | DIVERGES | DIVERGES | both | TODO | - | Spec: `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#32-send_ok`, `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#32-message`, `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#32-messages`; Audit: `relay#confirmed-divergences` / `ios#confirmed-divergences` |
| DELIV-PER-DEVICE-ACK-BINDING | Per-device delivery keying | Delivery/ack must bind to `(wayfarer_id, device_id, msg_id)` and not cross-suppress devices. | DIVERGES | VERIFY | both | TODO | - | Spec: `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#63-per-device-tracking-and-ack-binding`; Audit: `relay#confirmed-divergences` / `ios#confirmed-matches` |
| DELIV-IDEMPOTENCY-CLIENT-MSG-ID | Idempotent resend support | When `client_msg_id` is present, relay must dedupe and enforce tuple invariants. | DIVERGES | VERIFY | aethos-relay | TODO | - | Spec: `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#62-retry-and-idempotency`; Audit: `relay#confirmed-divergences` / `ios#verify-items` |
| DELIV-TTL-DEFAULT-3600 | Default TTL semantics | Omitted `ttl_seconds` defaults to `3600` before max-TTL capping logic. | DIVERGES | VERIFY | aethos-relay | TODO | - | Spec: `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#2-shared-types`, `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#7-ttl-semantics`; Audit: `relay#confirmed-divergences` / `ios#confirmed-matches` |
| DELIV-EXPIRED-DELIVERY-BOUNDARY | Expired messages must not deliver | Messages with `now_seconds >= expires_at` must not be delivered. | DIVERGES | VERIFY | aethos-relay | TODO | - | Spec: `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#7-ttl-semantics`; Audit: `relay#confirmed-divergences` |
| DELIV-ACK-OK-ROUNDTRIP | `ack_ok` await/validation behavior | `ack_ok` confirms accepted ack; client flow should treat it as the ack response boundary. | OK | DIVERGES | aethos-ios | TODO | - | Spec: `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#64-receive-acknowledgment`; Audit: `relay#confirmed-matches` / `ios#confirmed-divergences` |
| DELIV-RETRY-POLICY | Retry/backoff policy conformance | Retry window/backoff guidance: 30s timeout, bounded retries, jittered backoff. | VERIFY | VERIFY | both | TODO | - | Spec: `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#62-retry-and-idempotency`; Audit: - |

## Message Retrieval

| Feature ID | Feature | Spec Expectation | Relay Status | iOS Status | Owner | Migration Status | Alignment Bead | Spec Reference |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| RETR-PULL-MESSAGES-FIELD-SHAPE | Pull response item schema | `messages[]` entries must include canonical `msg_id`, `from`, `payload_b64`, `received_at` fields. | DIVERGES | DIVERGES | both | TODO | - | Spec: `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#32-messages`; Audit: `relay#confirmed-divergences` / `ios#confirmed-divergences` |
| RETR-MESSAGES-STRICT-PARSING | Strict required-shape handling | `messages` frame should enforce required array/object shape instead of silently accepting malformed structures. | VERIFY | DIVERGES | aethos-ios | TODO | - | Spec: `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#32-messages`; Audit: `ios#confirmed-divergences` |
| RETR-PULL-LIMIT-DEFAULT | Pull limit default behavior | Omitted `pull.limit` defaults to `50`. | OK | VERIFY | both | TODO | - | Spec: `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#2-shared-types`, `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#31-pull`; Audit: `relay#confirmed-matches` |

## Error Handling

| Feature ID | Feature | Spec Expectation | Relay Status | iOS Status | Owner | Migration Status | Alignment Bead | Spec Reference |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| ERR-ERROR-FRAME-SCHEMA | Structured error payload schema | `error` must include `code` and `message` fields. | DIVERGES | DIVERGES | both | TODO | - | Spec: `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#32-error`; Audit: `relay#confirmed-divergences` / `ios#confirmed-divergences` |
| ERR-ERROR-CODE-VOCABULARY | Canonical error code set semantics | Error codes should map to canonical vocabulary (for example `TO_MISMATCH`, `INVALID_PAYLOAD`, `AUTH_FAILED`). | DIVERGES | VERIFY | aethos-relay | TODO | - | Spec: `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#32-error`; Audit: `relay#confirmed-divergences` / `ios#verify-items` |
| ERR-PRE-HELLO-ERROR-PATH | Pre-handshake rejection behavior | Relay should reject non-`hello` pre-handshake frames via canonical error path. | VERIFY | VERIFY | both | TODO | - | Spec: `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#5-ordering-and-connection-rules`; Audit: - |

## Federation Protocol

Note: iOS does not implement federation in MVP0. Federation rows use `NOT_IMPLEMENTED` for iOS to encode "not applicable for MVP0" within the allowed status vocabulary.

| Feature ID | Feature | Spec Expectation | Relay Status | iOS Status | Owner | Migration Status | Alignment Bead | Spec Reference |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| FED-WIRE-MODEL-ENVELOPE-FORWARD | Canonical federation wire model | Federation should use `relay_forward(envelope)` + canonical `relay_ack`/`relay_cover` model. | DIVERGES | NOT_IMPLEMENTED | aethos-relay | TODO | - | Spec: `docs/spec/FEDERATION_PROTOCOL_V1.md#3-frame-types`; Audit: `relay#confirmed-divergences` / `ios:-` |
| FED-HELLO-PROTOCOL-VERSION | `relay_hello.protocol_version` contract | `relay_hello` must carry integer `protocol_version = 1`. | DIVERGES | NOT_IMPLEMENTED | aethos-relay | TODO | - | Spec: `docs/spec/FEDERATION_PROTOCOL_V1.md#3-relay_hello`; Audit: `relay#confirmed-divergences` / `ios:-` |
| FED-RELAY-ACK-STATUS-MODEL | Relay ack status and reject payload | `relay_ack.status` must be `accepted\|rejected`; rejections require canonical code/message semantics. | DIVERGES | NOT_IMPLEMENTED | aethos-relay | TODO | - | Spec: `docs/spec/FEDERATION_PROTOCOL_V1.md#3-relay_ack`, `docs/spec/FEDERATION_PROTOCOL_V1.md#6-rejection-cases`; Audit: `relay#confirmed-divergences` / `ios:-` |
| FED-HOP-LIMIT-ENFORCEMENT | Hop limit checks and increment | Relay must reject `hop_count >= MAX_HOPS` and increment by 1 before forwarding. | DIVERGES | NOT_IMPLEMENTED | aethos-relay | TODO | - | Spec: `docs/spec/FEDERATION_PROTOCOL_V1.md#4-invariants-and-validation-rules`; Audit: `relay#confirmed-divergences` / `ios:-` |
| FED-SEEN-RELAYS-LOOP-PREVENTION | Loop prevention via `seen_relays` | Relay must append local relay, and reject if local relay already appears in `seen_relays`. | DIVERGES | NOT_IMPLEMENTED | aethos-relay | TODO | - | Spec: `docs/spec/FEDERATION_PROTOCOL_V1.md#4-invariants-and-validation-rules`; Audit: `relay#confirmed-divergences` / `ios:-` |
| FED-DESTINATION-HASH-INVARIANTS | Destination + envelope hash invariants | Relay must enforce `envelope_id = SHA-256(payload)` and `destination == toWayfarerId` decoded from payload. | DIVERGES | NOT_IMPLEMENTED | aethos-relay | TODO | - | Spec: `docs/spec/FEDERATION_PROTOCOL_V1.md#2-envelope-schema`, `docs/spec/FEDERATION_PROTOCOL_V1.md#4-invariants-and-validation-rules`; Audit: `relay#confirmed-divergences` / `ios:-` |
| FED-EXPIRY-BOUNDARY | Expiry comparison boundary | Expired envelopes must be rejected when `now_ms >= expires_at`. | DIVERGES | NOT_IMPLEMENTED | aethos-relay | TODO | - | Spec: `docs/spec/FEDERATION_PROTOCOL_V1.md#4-invariants-and-validation-rules`; Audit: `relay#confirmed-divergences` / `ios:-` |
| FED-TTL-NON-EXTENSION | `expires_at` immutability across hops | `expires_at` is immutable after creation; relays must not extend TTL across hops. | VERIFY | NOT_IMPLEMENTED | aethos-relay | TODO | - | Spec: `docs/spec/FEDERATION_PROTOCOL_V1.md#4-invariants-and-validation-rules`; Audit: `relay#verify-items-to-emphasize` / `ios:-` |
| FED-RELAY-COVER-SCHEMA | `relay_cover` field set and units | `relay_cover` should include `relay_id` and `sent_at` (Unix ms), with optional padding. | DIVERGES | NOT_IMPLEMENTED | aethos-relay | TODO | - | Spec: `docs/spec/FEDERATION_PROTOCOL_V1.md#3-relay_cover`; Audit: `relay#confirmed-divergences` / `ios:-` |

## Receipt Semantics

| Feature ID | Feature | Spec Expectation | Relay Status | iOS Status | Owner | Migration Status | Alignment Bead | Spec Reference |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| RCP-RECEIPT-WRAPPER-SUPPORT | Receipt wrapper support for mixed scopes | JSON channels carrying mixed scopes require `receipt_scope` + `receipt_v1_b64` wrapper. | DIVERGES | VERIFY | both | TODO | - | Spec: `docs/spec/RECEIPTS.md#41-json-transport-wrapper`; Audit: `relay#confirmed-divergences` |
| RCP-NON-CONFLATION | Device vs federation non-conflation | `DeviceReceipt` and `FederationReceipt` semantics must remain distinct. | OK | VERIFY | both | TODO | - | Spec: `docs/spec/RECEIPTS.md#3-non-conflation-requirement`; Audit: `relay#confirmed-matches` |
| RCP-ACK-TRANSPORT-VS-RECEIPT | `ack_ok` transport vs receipt semantics | `ack_ok` transport response semantics must remain separate from `ReceiptV1` semantics. | OK | VERIFY | both | TODO | - | Spec: `docs/spec/RECEIPTS.md#3-non-conflation-requirement`, `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#32-ack_ok`; Audit: `relay#confirmed-matches` / `ios#verify-items` |
| RCP-IOS-STATUS-VOCABULARY-MAPPING | Client status vocabulary mapping | Client-facing receipt/delivery vocabulary should align with canonical device-level receipt semantics. | VERIFY | DIVERGES | aethos-ios | TODO | - | Spec: `docs/spec/RECEIPTS.md#2-vocabulary-layer`, `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#63-per-device-tracking-and-ack-binding`, `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#64-receive-acknowledgment`; Audit: `ios#confirmed-divergences` |

## Updating the Matrix

- Keep `Feature ID` stable once introduced; never repurpose an ID for a different semantic.
- Never delete rows; retain history and update status fields as implementation evolves.
- Update Relay/iOS status directly from implementation audits, not inferred assumptions.
- Add the owning migration bead ID in `Alignment Bead` when work is scheduled or in progress.

## Sources

- Relay divergence audit (authoritative): `https://github.com/natemellendorf/aethos-relay/blob/main/docs/PROTOCOL_DIVERGENCES.md`
- iOS divergence audit (authoritative): `https://github.com/natemellendorf/aethos-ios/blob/main/docs/PROTOCOL_DIVERGENCES.md`
- Audit shorthand in rows: `relay#...` and `ios#...` map to heading anchors in the two audit docs above.
- Canonical client-relay spec: `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md`
- Canonical federation spec: `docs/spec/FEDERATION_PROTOCOL_V1.md`
- Canonical receipt spec: `docs/spec/RECEIPTS.md`
- Migration plan: `docs/migration/protocol_update.md`
