# Client-Relay Conformance Fixtures

Status: Draft fixture contract for client-relay protocol alignment

Purpose: define fixture families used as objective evidence for compatibility-matrix updates and canonical-only legacy cleanup.

## Fixture Families

| Fixture ID | Scope | Evidence target |
| --- | --- | --- |
| CRF-HELLO-DEVICE-ID | `hello` required fields | `CRP-HELLO-DEVICE-ID` |
| CRF-HELLO-WAYFARER-FORMAT | `wayfarer_id` format validation | `CRP-HELLO-WAYFARER-ID-FORMAT` |
| CRF-HELLO-OK-RELAY-ID | `hello_ok.relay_id` required field | `CRP-HELLO-OK-RELAY-ID` |
| CRF-PAYLOAD-BASE64URL | `payload_b64` encoding acceptance/rejection | `CRP-PAYLOAD-BASE64URL` |
| CRF-SEND-TO-MISMATCH | `send.to` vs envelope invariant + `TO_MISMATCH` | `CRP-SEND-TO-MISMATCH-INVARIANTS` |
| CRF-SEND-OK-TIMESTAMPS | Canonical `send_ok` timestamp fields | `DELIV-TIMESTAMP-FIELD-MAPPING` |
| CRF-TIMESTAMP-UNITS-SECONDS | Client-relay timestamp unit guardrails (`received_at`/`expires_at` in seconds) | `DELIV-TTL-DEFAULT-3600`, `DELIV-EXPIRED-DELIVERY-BOUNDARY` |
| CRF-ACK-BINDING-PER-DEVICE | Per-device ack suppression boundary | `DELIV-PER-DEVICE-ACK-BINDING` |
| CRF-ACK-OK-ROUNDTRIP | `ack_ok` await/validation behavior at client boundary | `DELIV-ACK-OK-ROUNDTRIP` |
| CRF-CLIENT-MSG-ID-OPTIONAL | `client_msg_id` optional canonical/back-compat behavior | `DELIV-IDEMPOTENCY-CLIENT-MSG-ID` |
| CRF-IDEMPOTENCY-TUPLE | Idempotency tuple dedupe and mismatch rejection | `DELIV-IDEMPOTENCY-CLIENT-MSG-ID` |
| CRF-PULL-MESSAGES-SHAPE | `messages[]` canonical required shape | `RETR-PULL-MESSAGES-FIELD-SHAPE`, `RETR-MESSAGES-STRICT-PARSING` |
| CRF-ERROR-SCHEMA-CODES | Canonical `error.code` + `error.message` vocabulary | `ERR-ERROR-FRAME-SCHEMA`, `ERR-ERROR-CODE-VOCABULARY` |
| CRF-RECEIPT-SCOPE-WRAPPER | Mixed-scope receipt wrapper (`receipt_scope`, `receipt_v1_b64`) | `RCP-RECEIPT-WRAPPER-SUPPORT` |
| CRF-RECEIPT-NON-CONFLATION | Device vs federation receipt non-conflation invariant | `RCP-NON-CONFLATION`, `RCP-ACK-TRANSPORT-VS-RECEIPT` |

## Evidence Requirements

For every compatibility row moved to canonical-only:

1. Relevant fixture family cases must pass in implementation repos.
2. Matrix row status must be updated with fixture evidence and migration state.
3. Legacy behavior may be removed only after both conditions are met.

## See also

- Legacy cleanup plan: [`docs/migration/CLIENT_RELAY_LEGACY_CLEANUP_PLAN.md`](./CLIENT_RELAY_LEGACY_CLEANUP_PLAN.md)
- Compatibility matrix: [`docs/migration/PROTOCOL_COMPATIBILITY_MATRIX.md`](./PROTOCOL_COMPATIBILITY_MATRIX.md)
- Migration plan: [`docs/migration/protocol_update.md`](./protocol_update.md)
- Canonical client-relay spec: [`docs/spec/CLIENT_RELAY_PROTOCOL_V1.md`](../spec/CLIENT_RELAY_PROTOCOL_V1.md)
- Canonical receipt spec: [`docs/spec/RECEIPTS.md`](../spec/RECEIPTS.md)
