# Client-Relay Conformance Fixtures

> Archived migration document (historical, non-normative).
> This fixture plan is retained for migration history only.
> Active normative transport contracts are defined in `docs/spec/*`.

Status: Draft fixture contract for client-relay protocol alignment

Purpose: define fixture families used as objective evidence for compatibility-matrix updates and canonical-only legacy cleanup.

## Fixture Families

| Fixture ID | Scope | Evidence target |
| --- | --- | --- |
| CRF-HELLO-DEVICE-ID | `hello` required fields | `CRP-HELLO-DEVICE-ID` |
| CRF-HELLO-WAYFARER-FORMAT | `wayfarer_id` format validation | `CRP-HELLO-WAYFARER-ID-FORMAT` |
| CRF-HELLO-OK-RELAY-ID | `hello_ok.relay_id` required field | `CRP-HELLO-OK-RELAY-ID` |
| CRF-HANDSHAKE-ORDERING | Handshake ordering and gating rules | `CRP-HANDSHAKE-ORDERING` |
| CRF-PRE-HELLO-ERROR-PATH | Canonical pre-handshake error path | `ERR-PRE-HELLO-ERROR-PATH` |
| CRF-PAYLOAD-BASE64URL | `payload_b64` encoding acceptance/rejection | `CRP-PAYLOAD-BASE64URL` |
| CRF-SEND-TO-MISMATCH | `send.to` vs envelope invariant + `TO_MISMATCH` | `CRP-SEND-TO-MISMATCH-INVARIANTS` |
| CRF-SEND-OK-TIMESTAMPS | Canonical `send_ok` timestamp fields | `DELIV-TIMESTAMP-FIELD-MAPPING` |
| CRF-TIMESTAMP-UNITS-SECONDS | Client-relay timestamp unit guardrails (`received_at`/`expires_at` in seconds) | `DELIV-TTL-DEFAULT-3600`, `DELIV-EXPIRED-DELIVERY-BOUNDARY` |
| CRF-TTL-DEFAULT-3600 | Omitted `send.ttl_seconds` canonical default behavior | `DELIV-TTL-DEFAULT-3600` |
| CRF-EXPIRED-DELIVERY-BOUNDARY | Expiry boundary (`now_seconds >= expires_at`) enforcement | `DELIV-EXPIRED-DELIVERY-BOUNDARY` |
| CRF-ACK-BINDING-PER-DEVICE | Per-device ack suppression boundary | `DELIV-PER-DEVICE-ACK-BINDING` |
| CRF-ACK-OK-ROUNDTRIP | `ack_ok` await/validation behavior at client boundary | `DELIV-ACK-OK-ROUNDTRIP` |
| CRF-CLIENT-MSG-ID-OPTIONAL | `client_msg_id` optional canonical/back-compat behavior | `DELIV-IDEMPOTENCY-CLIENT-MSG-ID` |
| CRF-IDEMPOTENCY-TUPLE | Idempotency tuple dedupe and mismatch rejection | `DELIV-IDEMPOTENCY-CLIENT-MSG-ID` |
| CRF-PULL-MESSAGES-SHAPE | `messages[]` canonical required shape | `RETR-PULL-MESSAGES-FIELD-SHAPE`, `RETR-MESSAGES-STRICT-PARSING` |
| CRF-MESSAGES-STRICT-PARSING | Reject malformed `messages` frame shape | `RETR-MESSAGES-STRICT-PARSING` |
| CRF-PULL-LIMIT-DEFAULT | Omitted `pull.limit` canonical default behavior | `RETR-PULL-LIMIT-DEFAULT` |
| CRF-ERROR-SCHEMA-CODES | Canonical `error.code` + `error.message` vocabulary | `ERR-ERROR-FRAME-SCHEMA`, `ERR-ERROR-CODE-VOCABULARY` |
| CRF-RECEIPT-SCOPE-WRAPPER | Mixed-scope receipt wrapper (`receipt_scope`, `receipt_v1_b64`) | `RCP-RECEIPT-WRAPPER-SUPPORT` |
| CRF-RECEIPT-NON-CONFLATION | Device vs federation receipt non-conflation invariant | `RCP-NON-CONFLATION`, `RCP-ACK-TRANSPORT-VS-RECEIPT` |

## Evidence Requirements

For every compatibility row moved to canonical-only:

1. Relevant fixture family cases must pass in implementation repos.
2. Matrix row status must be updated with fixture evidence and migration state.
3. Legacy behavior may be removed only after both conditions are met.

## Minimal Objective Cases

Each fixture family below defines minimal objective evidence with explicit **MUST PASS** and **MUST FAIL** cases.

### CRF-HELLO-DEVICE-ID

- MUST PASS: `hello` with valid `wayfarer_id` + `device_id` is accepted and yields `hello_ok`.
- MUST FAIL: `hello` missing `device_id` is rejected via canonical `error` path.

### CRF-HELLO-WAYFARER-FORMAT

- MUST PASS: `hello.wayfarer_id` as lowercase 64-char hex is accepted.
- MUST FAIL: uppercase or non-hex `wayfarer_id` is rejected.

### CRF-HELLO-OK-RELAY-ID

- MUST PASS: relay emits `hello_ok` with required `relay_id`.
- MUST FAIL: `hello_ok` missing `relay_id` fails client parser conformance.

### CRF-HANDSHAKE-ORDERING

- MUST PASS: client sends `hello`, receives `hello_ok`, then `send`/`pull`/`ack` succeeds.
- MUST FAIL: pre-`hello_ok` non-`hello` frame is rejected.

### CRF-PRE-HELLO-ERROR-PATH

- MUST PASS: pre-handshake non-`hello` frame yields canonical `error {type,code,message}` before close/termination path.
- MUST FAIL: silent drop or non-canonical pre-handshake rejection payload.

### CRF-PAYLOAD-BASE64URL

- MUST PASS: unpadded base64url `payload_b64` decodes to canonical `EnvelopeV1` bytes.
- MUST FAIL: standard-base64 alphabet and/or padded payload is rejected.

### CRF-SEND-TO-MISMATCH

- MUST PASS: `send.to` matching decoded `EnvelopeV1.toWayfarerId` is accepted.
- MUST FAIL: mismatch is rejected with `error.code = TO_MISMATCH`.

### CRF-SEND-OK-TIMESTAMPS

- MUST PASS: `send_ok` is accepted in canonical shapes `{type,msg_id}` and `{type,msg_id,received_at,expires_at}`.
- MUST FAIL: `send_ok` with only one of `received_at`/`expires_at` (or legacy `at` alias) is rejected by strict canonical parser mode.

### CRF-TIMESTAMP-UNITS-SECONDS

- MUST PASS: `received_at`/`expires_at` values are interpreted as Unix epoch seconds.
- MUST FAIL: ms-scale timestamp values treated as valid seconds semantics.

### CRF-TTL-DEFAULT-3600

- MUST PASS: omitted `send.ttl_seconds` enforces an effective 3600-second lifetime (before max-TTL capping), validated under a controlled clock/time-travel harness where `t0` is the harness `now_seconds` (or controlled clock baseline) at the moment the relay accepts the message for storage/delivery evaluation; for this fixture, “deliverable” means the message appears in `pull.messages[]` for the recipient (for example: appears at `t0+3599`, does not appear at `t0+3600`).
- MUST FAIL: omitted TTL using a non-3600 default (observed as too-early or too-late expiry under the same `t0` baseline and `pull.messages[]` observability rule).
- Fixture observability and boundary rule: this fixture does **not** require `send_ok` timestamps; evaluators MUST use delivery behavior only, and the canonical non-deliverable boundary is `now_seconds >= expires_at`.

### CRF-EXPIRED-DELIVERY-BOUNDARY

- MUST PASS: message with `now_seconds < expires_at` remains deliverable.
- MUST FAIL: message with `now_seconds >= expires_at` is delivered.

### CRF-ACK-BINDING-PER-DEVICE

- MUST PASS: `ack(msg_id)` from device A clears only `(wayfarer_id, device_id=A, msg_id)` pending state.
- MUST FAIL: device A `ack` suppresses delivery for device B under same `wayfarer_id`.

### CRF-ACK-OK-ROUNDTRIP

- MUST PASS: client waits for and validates canonical `ack_ok(msg_id)` as ack response boundary.
- MUST FAIL: fire-and-forget ack flow marks completion without receiving/validating `ack_ok`.

### CRF-CLIENT-MSG-ID-OPTIONAL

- MUST PASS: `send` without `client_msg_id` is accepted (best-effort idempotency mode).
- MUST FAIL: relay/client rejects canonical send solely because `client_msg_id` is absent.

### CRF-IDEMPOTENCY-TUPLE

- MUST PASS: retry with same `(sender_wayfarer_id, client_msg_id)` and same tuple returns the same `msg_id`.
- MUST PASS (conditional): if timestamp fields are included in both `send_ok` responses, `received_at` and `expires_at` are identical across retries.
- Timestamp omission rule: if timestamp fields are omitted, fixture assertions are limited to stable `msg_id` (no timestamp equality requirement).
- MUST FAIL: same idempotency key with changed tuple is accepted instead of `IDEMPOTENCY_MISMATCH`.

### CRF-PULL-MESSAGES-SHAPE

- MUST PASS: `messages[]` items include required `msg_id`, `from`, `payload_b64`, `received_at` fields.
- MUST FAIL: missing required field in a `messages[]` item is accepted as canonical.

### CRF-MESSAGES-STRICT-PARSING

- MUST PASS: canonical `messages` frame object+array shape parses successfully.
- MUST FAIL: malformed `messages` container (non-array or wrong item type) is silently accepted.

### CRF-PULL-LIMIT-DEFAULT

- MUST PASS: omitted `pull.limit` behaves as limit `50`.
- MUST FAIL: omitted `pull.limit` behaves as value other than `50`.

### CRF-ERROR-SCHEMA-CODES

- MUST PASS: `error` frame includes both `code` and `message` with canonical code vocabulary.
- MUST FAIL: ad hoc/missing `error` fields or unknown non-canonical code accepted as canonical.

### CRF-RECEIPT-SCOPE-WRAPPER

- MUST PASS: mixed-scope JSON receipt transport uses `receipt_scope` + `receipt_v1_b64` wrapper.
- MUST FAIL: mixed-scope channel accepts unscoped raw receipt payloads.

### CRF-RECEIPT-NON-CONFLATION

- MUST PASS: device and federation receipt flows remain semantically distinct.
- MUST FAIL: `FederationReceipt` treated as device-delivery confirmation, or `ack_ok` treated as `ReceiptV1`.

## See also

- Legacy cleanup plan: [`docs/migration/CLIENT_RELAY_LEGACY_CLEANUP_PLAN.md`](./CLIENT_RELAY_LEGACY_CLEANUP_PLAN.md)
- Compatibility matrix: [`docs/migration/PROTOCOL_COMPATIBILITY_MATRIX.md`](./PROTOCOL_COMPATIBILITY_MATRIX.md)
- Migration plan: [`docs/migration/protocol_update.md`](./protocol_update.md)
- Canonical client-relay spec: [`docs/spec/CLIENT_RELAY_PROTOCOL_V1.md`](../../spec/CLIENT_RELAY_PROTOCOL_V1.md)
- Canonical receipt spec: [`docs/spec/RECEIPTS.md`](../../spec/RECEIPTS.md)
