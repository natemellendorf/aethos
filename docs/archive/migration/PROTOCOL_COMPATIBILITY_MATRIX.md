# Protocol Compatibility Matrix (Migration Scoreboard)

> Archived migration document (historical, non-normative).
> This compatibility scoreboard is retained for migration history only.
> Active normative protocol contracts are defined in `docs/protocol/*` and `docs/spec/*`.

Purpose: track implementation alignment against canonical protocol specs across `aethos-relay` and `aethos-ios`, and map each gap to migration work. Related migration plan: [protocol_update.md](./protocol_update.md).

## See also

- [Legacy cleanup plan](./CLIENT_RELAY_LEGACY_CLEANUP_PLAN.md)
- [Client-relay conformance fixtures](./CLIENT_RELAY_CONFORMANCE_FIXTURES.md)
- [Migration plan](./protocol_update.md)
- [Architecture companion](./protocol_architecture.md)
- [Gossip v1 protocol docs](../../protocol/gossip.md)
- [Gossip v1 interoperability fixtures](../../../Fixtures/Protocol/gossip-v1/README.md)

Related migration references:

- Architecture companion: `docs/archive/migration/protocol_architecture.md`
- Gossip v1 upgrade docs: `docs/protocol/*`
- Gossip v1 interoperability fixtures: `Fixtures/Protocol/gossip-v1/*`

## Progress Summary

- Total Features: 33
- Aligned With Spec: 5
- Diverging From Spec: 14
- Verification Needed: 6

Counts are computed per row:

- **Aligned** when both Relay and iOS are `OK`.
- **Diverging** when either side is `DIVERGES`.
- **Verification Needed** when no side is `DIVERGES` and at least one side is `VERIFY`.
- Rows with any `NOT_IMPLEMENTED` status are included in **Total Features** but excluded from **Aligned**/**Diverging**/**Verification Needed** totals.

Note: these counts apply to the compatibility feature matrix rows below and do not include the Phase 4/5 kickoff scoreboard section.

## Phase 4/5 Kickoff Scoreboard (2026-03-08)

Status vocabulary for this section: `Specified` / `In progress` / `Not started` / `Implemented`.

| Track ID | Track | Status | Notes | Primary references |
| --- | --- | --- | --- | --- |
| P45-GOSSIP-CONTRACT | Gossip v1 upgrade contract | Specified | Canonical Gossip v1 upgrade contract is defined in `docs/protocol/*`; Phase 4/5 implementation rollout is active. | [Docs](../../protocol/gossip.md), [Fixtures](../../../Fixtures/Protocol/gossip-v1/README.md), [Phase 4 plan](./protocol_update.md#10-phase-4--gossip-v1-implementation) |
| P45-GOSSIPV1-RUNTIME | Transport-neutral Gossip V1 runtime implementation | In progress | Gossip V1 session integration work has started; fixture-backed convergence validation is still in progress across implementations. | [Phase 4 Step 4.3](./protocol_update.md#step-43--implement-transport-neutral-aethos-gossip-protocol-gossip-v1-runtime), [Gossip docs](../../protocol/gossip.md) |
| P45-LOCAL-DISCOVERY | Local peer discovery | In progress | Local discovery rollout has started; iOS reports Bonjour/mDNS discovery implementation in progress. | [Phase 5 plan](./protocol_update.md#11-phase-5--lan-discovery-and-local-peer-delivery), [Phase 5 Step 5.2](./protocol_update.md#step-52--implement-ios-local-discovery) |
| P45-PEER-TABLE | Peer-table tracking | In progress | Peer-table tracking is underway for discovered identities/endpoints/last-seen and diagnostics visibility. | [Phase 5 Step 5.4](./protocol_update.md#step-54--build-peer-table-abstraction), [Phase 5 Step 5.6](./protocol_update.md#step-56--add-diagnostics-ui-and-logs) |
| P45-DISCOVERY-SYNC-INTEGRATION | Discovery-driven sync integration | In progress | Discovery-triggered connection + gossip wiring has started; full end-to-end evidence remains tracked as rollout work. | [Phase 5 Step 5.5](./protocol_update.md#step-55--trigger-sync-on-discovery-driven-connection), [Gossip docs](../../protocol/gossip.md) |

## Schema

| Feature ID | Feature | Spec Expectation | Relay Status | iOS Status | Owner | Migration Status | Alignment Bead | Spec Reference |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |

Status vocab:

- Relay/iOS Status: `OK` / `DIVERGES` / `VERIFY` / `NOT_IMPLEMENTED`
- Migration Status: `TODO` / `IN_PROGRESS` / `COMPLETE`
- Owner: `aethos-relay` / `aethos-ios` / `both` (`both` means coordinated rollout and validation are required across repos)

## Client Relay Protocol

| Feature ID | Feature | Spec Expectation | Relay Status | iOS Status | Owner | Migration Status | Alignment Bead | Spec Reference |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| CRP-HELLO-DEVICE-ID | `hello.device_id` required | `hello` must include `wayfarer_id` + `device_id` in v1. | OK | OK | both | COMPLETE | Bead: aethos-a01 | Spec: `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#3-frame-types` (`hello` frame under Client -> Relay); Evidence: relay `dba3f9f` (`internal/api/ws.go`, `tests/compatibility_harness_test.go`), ios `1874fe4`/`e60c471` (`WayfarerApp/CoreBridge/RelayWebSocketClient.swift`, `WayfarerApp/CoreBridgeTests/Fixtures/ClientRelayV1/client_hello_canonical_encode.json`). |
| CRP-HELLO-WAYFARER-ID-FORMAT | `wayfarer_id` format validation | `wayfarer_id` must be lowercase 64-char hex (`[0-9a-f]{64}`). | DIVERGES | VERIFY | aethos-relay | TODO | - | Spec: `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#2-shared-types`; Audit: `relay#confirmed-divergences` |
| CRP-HELLO-OK-RELAY-ID | `hello_ok.relay_id` required | `hello_ok` must include `relay_id`. | OK | VERIFY | both | IN_PROGRESS | Bead: aethos-a01 | Spec: `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#3-frame-types` (`hello_ok` frame under Relay -> Client); Evidence: relay `dba3f9f` (`internal/api/ws.go`, `internal/api/ws_test.go`). Residual: iOS canonical-only rejection for missing `relay_id` is not yet verified in runtime tests. |
| CRP-PAYLOAD-BASE64URL | `payload_b64` canonical encoding | `payload_b64` must be unpadded base64url canonical `EnvelopeV1` bytes. | OK | DIVERGES | both | IN_PROGRESS | Bead: aethos-a01 | Spec: `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#1-transport-and-encoding`; Evidence: relay `dba3f9f` (`internal/model/payload_b64.go`, `internal/api/ws.go`). Residual: iOS runtime default codec still allows legacy inbound payload forms (`ClientRelayV1Codec` default `.canonicalPreferredLegacyFallback`). |
| CRP-SEND-TO-MISMATCH-INVARIANTS | Canonical send acceptance invariants | Relay must decode canonical envelope bytes and reject `send.to` mismatches with `TO_MISMATCH`. | DIVERGES | VERIFY | aethos-relay | TODO | - | Spec: `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#61-send-acceptance`; Audit: `relay#confirmed-divergences` |
| CRP-HANDSHAKE-ORDERING | Handshake gating before other frames | Client must wait for `hello_ok`; relay must reject pre-handshake non-`hello` frames. | OK | OK | both | COMPLETE | Bead: aethos-a01 | Spec: `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#5-ordering-and-connection-rules`; Evidence: relay `dba3f9f` (`internal/api/ws.go` guards on unauthenticated send/pull/ack with canonical `error`), ios `e60c471` (`RelayWebSocketClient.sendHello` readiness boundary). |
| CRP-ACK-FRAME-SHAPE | Transport ack frame shape | `ack(msg_id)` and `ack_ok(msg_id)` frame fields follow v1 contract. | OK | OK | both | COMPLETE | - | Spec: `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#3-frame-types` (`ack` and `ack_ok` frames); Audit: `relay#confirmed-matches` / `ios#confirmed-matches` |

## Delivery Semantics

| Feature ID | Feature | Spec Expectation | Relay Status | iOS Status | Owner | Migration Status | Alignment Bead | Spec Reference |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| DELIV-TIMESTAMP-FIELD-MAPPING | `at` vs `received_at` / `expires_at` | `message`/`messages` use `received_at`; `send_ok` uses canonical `{type,msg_id}` or optional paired `received_at` + `expires_at`. | OK | DIVERGES | both | IN_PROGRESS | Bead: aethos-a01 | Spec: `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#3-frame-types` (`message`/`messages`/`send_ok` frames), `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#7-ttl-semantics-normative`; Evidence: relay `dba3f9f` canonical emission without legacy `at` (`internal/api/ws.go`, `internal/api/ws_test.go`). Residual: iOS runtime compatibility mode still accepts legacy timestamp aliasing and unpaired timestamp tolerance (`ClientRelayV1Codec`). |
| DELIV-PER-DEVICE-ACK-BINDING | Per-device delivery keying | Delivery/ack must bind to `(wayfarer_id, device_id, msg_id)` and not cross-suppress devices. | OK | OK | both | COMPLETE | Bead: aethos-a01 | Spec: `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#63-per-device-tracking-and-ack-binding-v1-requirement`; Evidence: relay `dba3f9f` (`internal/api/ws.go`, `internal/storeforward/client.go`, `tests/compatibility_harness_test.go`), ios `e60c471` (client sends device-bound `hello`; relay-side canonical binding asserted). Legacy wayfarer-only suppression fallback removed from relay runtime default path. |
| DELIV-IDEMPOTENCY-CLIENT-MSG-ID | Idempotent resend support | When `client_msg_id` is present, relay must dedupe and enforce tuple invariants. | DIVERGES | VERIFY | aethos-relay | TODO | - | Spec: `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#62-retry-and-idempotency`; Audit: `relay#confirmed-divergences` / `ios#verify-items` |
| DELIV-TTL-DEFAULT-3600 | Default TTL semantics | Omitted `ttl_seconds` defaults to `3600` before max-TTL capping logic. | DIVERGES | OK | aethos-relay | TODO | - | Spec: `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#2-shared-types`, `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#7-ttl-semantics-normative`; Audit: `relay#confirmed-divergences` / `ios#confirmed-matches` |
| DELIV-EXPIRED-DELIVERY-BOUNDARY | Expired messages must not deliver | Messages with `now_seconds >= expires_at` must not be delivered. | DIVERGES | VERIFY | aethos-relay | TODO | - | Spec: `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#7-ttl-semantics-normative`; Audit: `relay#confirmed-divergences` |
| DELIV-ACK-OK-ROUNDTRIP | `ack_ok` await/validation behavior | `ack_ok` confirms accepted ack; client flow should treat it as the ack response boundary. | OK | DIVERGES | aethos-ios | IN_PROGRESS | Bead: aethos — Verify and Update Receipt/Ack Status in Compatibility Matrix | Spec: `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#64-receive-acknowledgment`; Audit: `relay#confirmed-matches` / `ios#confirmed-divergences`; Notes: Relay returns canonical `ack_ok {type,msg_id}`; iOS parses canonical/legacy `ack_ok` shapes but ack send remains fire-and-forget and does not await `ack_ok`. |
| DELIV-RETRY-POLICY | Retry/backoff policy conformance | Retry window/backoff guidance: 30s timeout, bounded retries, jittered backoff. | VERIFY | VERIFY | both | TODO | - | Spec: `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#62-retry-and-idempotency`; Audit: none (not yet audited) |

## Message Retrieval

| Feature ID | Feature | Spec Expectation | Relay Status | iOS Status | Owner | Migration Status | Alignment Bead | Spec Reference |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| RETR-PULL-MESSAGES-FIELD-SHAPE | Pull response item schema | `messages[]` entries must include canonical `msg_id`, `from`, `payload_b64`, `received_at` fields. | OK | DIVERGES | both | IN_PROGRESS | Bead: aethos-a01 | Spec: `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#3-frame-types` (`messages` frame); Evidence: relay `dba3f9f` canonical `messages[]` emission (`internal/api/ws.go`, `internal/api/ws_test.go`, `tests/testdata/aethos/client_relay_v1/cases/02_canonical_rejections.json`). Residual: iOS parser remains compatibility-tolerant for legacy/non-strict `messages[]` forms in default mode. |
| RETR-MESSAGES-STRICT-PARSING | Strict required-shape handling | `messages` frame should enforce required array/object shape instead of silently accepting malformed structures. | VERIFY | DIVERGES | aethos-ios | TODO | - | Spec: `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#3-frame-types` (`messages` frame); Audit: `ios#confirmed-divergences` |
| RETR-PULL-LIMIT-DEFAULT | Pull limit default behavior | Omitted `pull.limit` defaults to `50`. | OK | VERIFY | both | TODO | - | Spec: `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#2-shared-types`, `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#3-frame-types` (`pull` frame); Audit: `relay#confirmed-matches` |

## Error Handling

| Feature ID | Feature | Spec Expectation | Relay Status | iOS Status | Owner | Migration Status | Alignment Bead | Spec Reference |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| ERR-ERROR-FRAME-SCHEMA | Structured error payload schema | `error` must include `code` and `message` fields. | OK | DIVERGES | both | IN_PROGRESS | Bead: aethos-a01 | Spec: `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#3-frame-types` (`error` frame); Evidence: relay `dba3f9f` (`internal/api/ws.go#sendError`, `tests/compatibility_harness_test.go`). Residual: iOS default runtime keeps legacy fallback parsing (`message -> code -> msg_id`) for migration tolerance. |
| ERR-ERROR-CODE-VOCABULARY | Canonical error code set semantics | Error codes should map to canonical vocabulary (for example `TO_MISMATCH`, `INVALID_PAYLOAD`, `AUTH_FAILED`). | OK | VERIFY | both | IN_PROGRESS | Bead: aethos-a01 | Spec: `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#3-frame-types` (`error` frame code set); Evidence: relay `dba3f9f` error emissions via `model.ErrorCode*` constants and `sendError`. Residual: iOS-side strict vocabulary handling remains verification-only. |
| ERR-PRE-HELLO-ERROR-PATH | Pre-handshake rejection behavior | Relay should reject non-`hello` pre-handshake frames via canonical error path. | OK | VERIFY | both | IN_PROGRESS | Bead: aethos-a01 | Spec: `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#5-ordering-and-connection-rules`; Evidence: relay unauthenticated send/pull/ack guards in `internal/api/ws.go` emit canonical `error` frames. Residual: explicit end-to-end pre-hello close-path fixture coverage in iOS client flow remains unverified. |

## Client-Relay Cutover Readiness (2026-03-08)

- **Relay canonical-only cutover:** Substantially complete for handshake identity, canonical `messages`/`send_ok` shapes, canonical `error` frame shape, base64url payload enforcement, and per-device ack binding.
- **iOS canonical-only runtime cutover:** **Not complete**; canonical fixture scaffolding exists, but runtime default remains compatibility mode for several legacy parse paths.
- **Go/No-go for next phase:** **GO (conditional)** — enough alignment to begin transport-neutral Gossip V1 implementation + LAN discovery work, with residual exceptions tracked below.

### Residual exceptions (canonical-only not fully closed)

- `CRP-HELLO-WAYFARER-ID-FORMAT`: relay still accepts non-canonical `wayfarer_id` forms.
- `CRP-HELLO-OK-RELAY-ID`: iOS strict rejection of missing `relay_id` is not yet verified.
- `CRP-PAYLOAD-BASE64URL`: iOS runtime still allows legacy inbound payload forms in default mode.
- `CRP-SEND-TO-MISMATCH-INVARIANTS`: relay invariant enforcement remains incomplete.
- `DELIV-TIMESTAMP-FIELD-MAPPING`: iOS runtime retains legacy timestamp tolerance in default mode.
- `DELIV-IDEMPOTENCY-CLIENT-MSG-ID`: relay still lacks full `client_msg_id` idempotency tuple contract.
- `DELIV-TTL-DEFAULT-3600`: relay default TTL still diverges from canonical 3600-second default.
- `DELIV-EXPIRED-DELIVERY-BOUNDARY`: relay expiry boundary behavior remains a known divergence.
- `DELIV-ACK-OK-ROUNDTRIP`: iOS ack flow remains fire-and-forget and does not await/validate `ack_ok`.
- `RETR-MESSAGES-STRICT-PARSING`: iOS parser still accepts/skips malformed `messages[]` entries in compatibility mode.

## Client-Relay Cutover Readiness (2026-03-08)

### Residual exceptions (verification-only; no known DIVERGES on row)

- `CRP-HANDSHAKE-ORDERING`: relay-side verification is still open for pre-`hello_ok` gating and pre-handshake rejection behavior.
- `ERR-PRE-HELLO-ERROR-PATH`: end-to-end verification for canonical pre-hello error + close-path behavior remains open.
- `RETR-PULL-LIMIT-DEFAULT`: iOS verification for omitted `pull.limit` defaulting to `50` remains open.
- `DELIV-RETRY-POLICY`: retry/backoff policy conformance remains unverified on both sides.
- `RCP-NON-CONFLATION`: iOS verification remains open to confirm device/federation receipt semantics stay non-conflated in runtime behavior.

### Residual divergences (still DIVERGES on row)

- `ERR-ERROR-CODE-VOCABULARY`: relay still diverges from the canonical error-code vocabulary, and iOS strict canonical-code handling is also still unverified.

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
| RCP-RECEIPT-WRAPPER-SUPPORT | Receipt wrapper support for mixed scopes | JSON channels carrying mixed scopes require `receipt_scope` + `receipt_v1_b64` wrapper. | DIVERGES | VERIFY | both | TODO | - | Spec: `docs/spec/RECEIPTS.md#41-json-transport-wrapper-normative-for-json-channels`; Audit: `relay#confirmed-divergences` |
| RCP-NON-CONFLATION | Device vs federation non-conflation | `DeviceReceipt` and `FederationReceipt` semantics must remain distinct. | OK | VERIFY | both | TODO | - | Spec: `docs/spec/RECEIPTS.md#3-non-conflation-requirement`; Audit: `relay#confirmed-matches` |
| RCP-ACK-TRANSPORT-VS-RECEIPT | `ack_ok` transport vs receipt semantics | `ack_ok` transport response semantics must remain separate from `ReceiptV1` semantics. | OK | OK | both | COMPLETE | Bead: aethos — Verify and Update Receipt/Ack Status in Compatibility Matrix | Spec: `docs/spec/RECEIPTS.md#3-non-conflation-requirement`, `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#3-frame-types` (`ack_ok` frame); Audit: `relay#confirmed-matches` / `ios#confirmed-matches`; Notes: Both repos keep `ack`/`ack_ok` transport-level and do not treat them as `ReceiptV1`; explicit receipt wrappers remain tracked in `RCP-RECEIPT-WRAPPER-SUPPORT`. |
| RCP-IOS-STATUS-VOCABULARY-MAPPING | Client status vocabulary mapping | Client-facing receipt/delivery vocabulary should align with canonical device-level receipt semantics. | OK | DIVERGES | aethos-ios | IN_PROGRESS | Bead: aethos — Verify and Update Receipt/Ack Status in Compatibility Matrix | Spec: `docs/spec/RECEIPTS.md#2-vocabulary-layer`, `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#63-per-device-tracking-and-ack-binding-v1-requirement`, `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#64-receive-acknowledgment`; Audit: `ios#confirmed-divergences`; Notes: iOS app-layer status vocabulary remains local send-state oriented (`queued/sent/failed`) rather than canonical device-receipt vocabulary. |

## Updating the Matrix

- Keep `Feature ID` stable once introduced; never repurpose an ID for a different semantic.
- Never delete rows; retain history and update status fields as implementation evolves.
- Update Relay/iOS status directly from implementation audits, not inferred assumptions.
- Add the owning migration bead ID in `Alignment Bead` when work is scheduled or in progress.
- Use fixture evidence from [CLIENT_RELAY_CONFORMANCE_FIXTURES.md](./CLIENT_RELAY_CONFORMANCE_FIXTURES.md) when promoting compatibility rows toward canonical-only completion.

## Sources

- Relay divergence audit (authoritative): `https://github.com/natemellendorf/aethos-relay/blob/main/docs/PROTOCOL_DIVERGENCES.md`
- iOS divergence audit (authoritative): `https://github.com/natemellendorf/aethos-ios/blob/main/docs/PROTOCOL_DIVERGENCES.md`
- Relay canonical cleanup commit: `https://github.com/natemellendorf/aethos-relay/commit/dba3f9f93a5da54f9366da682eee1911076703d4`
- iOS fixture hardening commits: `https://github.com/natemellendorf/aethos-ios/commit/1874fe4c4b7f0ac68f730e1ed9efb86fdbf334fe`, `https://github.com/natemellendorf/aethos-ios/commit/e60c471f4b6fe02d31a449621c97e5175cc59779`
- Audit shorthand URL mapping:
  - `relay#<anchor>` -> `https://github.com/natemellendorf/aethos-relay/blob/main/docs/PROTOCOL_DIVERGENCES.md#<anchor>`
  - `ios#<anchor>` -> `https://github.com/natemellendorf/aethos-ios/blob/main/docs/PROTOCOL_DIVERGENCES.md#<anchor>`
- Audit shorthand legend:
  - `relay#confirmed-divergences`: relay audit confirms divergence.
  - `relay#confirmed-matches`: relay audit confirms match.
  - `relay#verify-items-to-emphasize`: relay audit lists this as verify/follow-up.
  - `ios#confirmed-divergences`: iOS audit confirms divergence.
  - `ios#confirmed-matches`: iOS audit confirms match.
  - `ios#verify-items`: iOS audit lists this as verify/follow-up.
  - `ios:-`: iOS audit does not currently provide explicit confirmation for the row.
  - `none (not yet audited)`: no audit evidence has been recorded yet.
- Canonical client-relay spec: `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md`
- Canonical federation spec: `docs/spec/FEDERATION_PROTOCOL_V1.md`
- Canonical receipt spec: `docs/spec/RECEIPTS.md`
- Migration plan: `docs/archive/migration/protocol_update.md`
