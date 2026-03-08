# Client-Relay Legacy Cleanup Plan

Status: Draft canonical-only cutover contract

## Purpose

Define the migration contract for removing legacy client-relay compatibility behavior and landing a canonical-only v1 wire contract across relay/client implementations.

## Scope

### In scope

- Legacy client-relay frame shapes and field aliases still accepted/emitted for transition.
- Canonical-only cutover rules for emit and accept behavior.
- Evidence gates required before removing each legacy behavior.
- Cross-repo cleanup sequencing (`aethos-relay` -> `aethos-ios` -> `aethos` verification).

### Out of scope

- Federation protocol cleanup (tracked separately in federation rows/beads).
- New protocol features or v2 schema design.
- Runtime heuristics unrelated to protocol compatibility.

## Definitions

- **Canonical-only**: only shapes/fields/semantics defined in `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md` and `docs/spec/RECEIPTS.md` are emitted and accepted.
- **Legacy behavior**: any non-canonical frame/field/semantic accepted or emitted for migration compatibility.
- **Transitional behavior**: temporary dual-support of canonical + legacy behavior with explicit removal gating via fixtures and matrix status.

## Legacy behavior inventory and removal contract

All rows require **both** fixture evidence and matrix state before removal. "Removal allowed now" reflects current migration docs/matrix status.

| Short name | Canonical behavior (fields/semantics) | Legacy behavior (accepted/emitted) | Repos affected | Removal allowed now? | Required validation evidence (fixtures + matrix) | References |
| --- | --- | --- | --- | --- | --- | --- |
| HELLO_DEVICE_ID_REQUIRED | `hello` MUST include `wayfarer_id` and `device_id`. | Relay accepts hello without `device_id`; iOS legacy clients may omit `device_id`. | relay, ios | No | Fixtures: `CRF-HELLO-DEVICE-ID`; Matrix: `CRP-HELLO-DEVICE-ID` -> `OK/OK`, `COMPLETE`. | [`CLIENT_RELAY_PROTOCOL_V1 §3.1 hello`](../spec/CLIENT_RELAY_PROTOCOL_V1.md#31-client---relay) |
| HELLO_WAYFARER_STRICT_FORMAT | `wayfarer_id` MUST be lowercase 64-char hex. | Relay accepts non-canonical `wayfarer_id` forms. | relay | No | Fixtures: `CRF-HELLO-WAYFARER-FORMAT`; Matrix: `CRP-HELLO-WAYFARER-ID-FORMAT` -> `OK`. | [`CLIENT_RELAY_PROTOCOL_V1 §2 shared types`](../spec/CLIENT_RELAY_PROTOCOL_V1.md#2-shared-types) |
| HELLO_OK_RELAY_ID_REQUIRED | `hello_ok` MUST include `relay_id`. | Relay may emit `hello_ok` without `relay_id`; clients may tolerate missing field. | relay, ios | No | Fixtures: `CRF-HELLO-OK-RELAY-ID`; Matrix: `CRP-HELLO-OK-RELAY-ID` -> `OK/OK`, `COMPLETE`. | [`CLIENT_RELAY_PROTOCOL_V1 §3.2 hello_ok`](../spec/CLIENT_RELAY_PROTOCOL_V1.md#32-relay---client) |
| PAYLOAD_BASE64URL_ONLY | `payload_b64` MUST be unpadded base64url canonical `EnvelopeV1` bytes. | Accept/emits legacy base64 variants (standard alphabet/padding). | relay, ios | No | Fixtures: `CRF-PAYLOAD-BASE64URL`; Matrix: `CRP-PAYLOAD-BASE64URL` -> `OK/OK`, `COMPLETE`. | [`CLIENT_RELAY_PROTOCOL_V1 §1`](../spec/CLIENT_RELAY_PROTOCOL_V1.md#1-transport-and-encoding) |
| SEND_TO_ENVELOPE_INVARIANT | Relay MUST enforce `send.to == hex_lower(EnvelopeV1.toWayfarerId)` and reject mismatch with `TO_MISMATCH`. | Relay accepts mismatched `to`/payload combinations. | relay | No | Fixtures: `CRF-SEND-TO-MISMATCH`; Matrix: `CRP-SEND-TO-MISMATCH-INVARIANTS` -> `OK`. | [`CLIENT_RELAY_PROTOCOL_V1 §6.1`](../spec/CLIENT_RELAY_PROTOCOL_V1.md#61-send-acceptance) |
| SEND_OK_TIMESTAMP_CANONICAL | `send_ok` uses canonical `received_at`/`expires_at` pairing (or omits both). | Transitional aliasing/lenient parse (`at` alias, `msg_id`-only tolerance). | relay, ios | No | Fixtures: `CRF-SEND-OK-TIMESTAMPS`; Matrix: `DELIV-TIMESTAMP-FIELD-MAPPING` -> `OK/OK`, `COMPLETE`. | [`CLIENT_RELAY_PROTOCOL_V1 §3.2 send_ok`](../spec/CLIENT_RELAY_PROTOCOL_V1.md#32-relay---client), [`§7 TTL`](../spec/CLIENT_RELAY_PROTOCOL_V1.md#7-ttl-semantics) |
| ACK_BINDING_DEVICE_SCOPED_ONLY | Ack binding/pending state keyed by `(wayfarer_id, device_id, msg_id)`; no cross-device suppression. | Relay legacy wayfarer-only fallback/suppression compatibility mode. | relay | No | Fixtures: `CRF-ACK-BINDING-PER-DEVICE`; Matrix: `DELIV-PER-DEVICE-ACK-BINDING` -> `OK/OK`, `COMPLETE`. | [`CLIENT_RELAY_PROTOCOL_V1 §6.3`](../spec/CLIENT_RELAY_PROTOCOL_V1.md#63-per-device-tracking-and-ack-binding-v1-requirement) |
| IDEMPOTENCY_TUPLE_STRICT | `client_msg_id` dedupe tuple must match exactly; mismatches return `IDEMPOTENCY_MISMATCH`. | Relaxed dedupe behavior or tuple mismatch acceptance. | relay, ios | No | Fixtures: `CRF-IDEMPOTENCY-TUPLE`; Matrix: `DELIV-IDEMPOTENCY-CLIENT-MSG-ID` -> `OK/OK`, `COMPLETE`. | [`CLIENT_RELAY_PROTOCOL_V1 §6.2`](../spec/CLIENT_RELAY_PROTOCOL_V1.md#62-retry-and-idempotency) |
| PULL_MESSAGES_CANONICAL_SHAPE_ONLY | `messages[]` items MUST include `msg_id`,`from`,`payload_b64`,`received_at`. | Legacy field names/shapes tolerated in emit or parse paths. | relay, ios | No | Fixtures: `CRF-PULL-MESSAGES-SHAPE`; Matrix: `RETR-PULL-MESSAGES-FIELD-SHAPE`, `RETR-MESSAGES-STRICT-PARSING` -> `OK/OK`, `COMPLETE`. | [`CLIENT_RELAY_PROTOCOL_V1 §3.2 messages`](../spec/CLIENT_RELAY_PROTOCOL_V1.md#32-relay---client) |
| ERROR_SCHEMA_CANONICAL_ONLY | `error` MUST include canonical `code` and `message`, with canonical vocabulary. | Ad hoc error schema/legacy codes tolerated. | relay, ios | No | Fixtures: `CRF-ERROR-SCHEMA-CODES`; Matrix: `ERR-ERROR-FRAME-SCHEMA`, `ERR-ERROR-CODE-VOCABULARY` -> `OK/OK`, `COMPLETE`. | [`CLIENT_RELAY_PROTOCOL_V1 §3.2 error`](../spec/CLIENT_RELAY_PROTOCOL_V1.md#32-relay---client) |
| RECEIPT_SCOPE_WRAPPER_REQUIRED | Mixed-scope JSON channels MUST use `receipt_scope` + `receipt_v1_b64`. | Unscoped receipt transport tolerated. | relay, ios | No | Fixtures: `CRF-RECEIPT-SCOPE-WRAPPER`; Matrix: `RCP-RECEIPT-WRAPPER-SUPPORT` -> `OK/OK`, `COMPLETE`. | [`RECEIPTS §4.1 JSON wrapper`](../spec/RECEIPTS.md#41-json-transport-wrapper), [`RECEIPTS §3`](../spec/RECEIPTS.md#3-non-conflation-requirement) |

Fixture family definitions are tracked in `docs/migration/CLIENT_RELAY_CONFORMANCE_FIXTURES.md`.

## Canonical-only cutover rules

1. **Clients MUST emit canonical frames only.**
2. **Relays MUST emit canonical frames only.**
3. **Relays MAY reject legacy-only client behavior once corresponding cleanup lands.**
4. **Fixture-based protocol tests are required evidence before any legacy removal.**
5. **Matrix gating is required for sign-off:** relevant rows must be updated to `OK/OK` (or `OK` for relay-only rows) with migration status `COMPLETE`.
6. **Operational rollout note:** no protocol version bump is currently documented for this cutover; rollout is gated by per-bead fixture pass + matrix state transitions across supported relay/client releases.

## Cleanup sequencing across repos

1. **Relay removal bead (`aethos-relay`)**
   - Remove relay-side legacy emit/accept fallback for rows owned by relay.
   - Land fixture coverage and update matrix evidence links.
2. **iOS removal bead (`aethos-ios`)**
   - Remove client-side legacy emit/parse fallback.
   - Confirm conformance fixtures against updated relay behavior.
3. **Post-removal verification bead (`aethos`)**
   - Re-run/confirm fixture matrix evidence references.
   - Update compatibility matrix rows to final canonical-only state.
   - Remove transitional notes that are no longer true.

## Do not remove yet

Current migration docs/matrix still indicate transitional behavior that must remain until evidence gates are met:

- Legacy timestamp compatibility around `send_ok` and parser tolerance (`DELIV-TIMESTAMP-FIELD-MAPPING` notes).
- Relay legacy per-wayfarer ack suppression fallback (`DELIV-PER-DEVICE-ACK-BINDING` notes).
- Legacy `ack_ok` handling expectations in iOS (`DELIV-ACK-OK-ROUNDTRIP`).
- Legacy/dual acceptance paths for hello fields, payload encoding, error schema/codes, and `messages[]` shape (rows listed above with `DIVERGES`/`VERIFY`/`IN_PROGRESS`).

Do not remove these compatibility paths until fixture + matrix gates in this contract are satisfied.
