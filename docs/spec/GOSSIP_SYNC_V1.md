# GOSSIP_SYNC_V1

Status: Canonical v1 contract (transport-neutral inventory sync)

This document defines the normative transport-neutral sync contract used to converge stored message inventories between peers.

- Canonical contract source: `docs/spec/*` (see `docs/adr/ADR-0001-protocol-contract-source-of-truth.md`)
- Core canonical structures and bytes: `docs/protocol.md`
- Related contracts: `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md`, `docs/spec/FEDERATION_PROTOCOL_V1.md`, `docs/spec/RECEIPTS.md`
- Conformance fixtures: `docs/migration/GOSSIP_SYNC_CONFORMANCE_FIXTURES.md`

## 1. Transport Neutrality and Encoding

1. This contract defines logical message types and field semantics independent of transport (WebSocket, HTTP, QUIC, relay-relay links, client-client links).
2. Field names and required/optional semantics in this document are normative.
3. For MVP0, binary transports SHOULD encode sync frames as CBOR.
4. JSON form MAY be used for debugging and conformance fixtures if it preserves identical field semantics.

## 2. Frozen Protocol Compatibility (MVP0)

This contract is aligned with frozen protocol decisions:

- IDs use SHA-256 where specified.
- Transfer payloads carry canonical `EnvelopeV1` bytes from `docs/protocol.md`.
- `EnvelopeV1.toWayfarerId` remains visible and is surfaced as `to_wayfarer_id` metadata.
- `chunk_size_bytes` is fixed at `32768` (32KB) in v1.
- Signature semantics remain Ed25519-compatible through existing envelope/receipt structures; this spec does not redefine signature primitives.

## 3. Shared Types

- `wayfarer_id`: lowercase hex, exactly 64 chars (`[0-9a-f]{64}`).
  - Canonical derivation remains `hex_lower(SHA-256(ed25519_public_key_raw_bytes))`.
- `item_id`: lowercase hex, exactly 64 chars; MUST equal `hex_lower(SHA-256(envelope_bytes))`.
- `manifest_id`: lowercase hex, exactly 64 chars; MUST equal canonical `ManifestV1` hash.
- `sync_version`: integer, MUST be `1` for this contract.
- `session_id`: opaque string identifier unique per sync attempt between a peer pair.
- `page`: integer, 1-based.
- `has_more`: boolean.
- `chunk_size_bytes`: integer, MUST be `32768`.
- `expires_at_unix_ms`: integer (`UInt64`) Unix epoch milliseconds.

Common required fields on all sync messages:

- `type`
- `sync_version`
- `session_id`
- `sender_wayfarer_id`
- `page`
- `has_more`

## 4. Message Types

Spec names and wire `type` values:

- `InventorySummary` -> `inventory_summary`
- `MissingRequest` -> `missing_request`
- `Transfer` -> `transfer`
- `Receipt` -> `receipt`

### 4.1 InventorySummary (`type = inventory_summary`)

Required fields:

- common required fields
- `inventory`: array of inventory entries

Required fields per inventory entry:

- `item_id`
- `manifest_id`
- `to_wayfarer_id`
- `expires_at_unix_ms`
- `total_size_bytes`
- `chunk_size_bytes` (MUST be `32768`)
- `chunk_count`

Field semantics:

- `inventory` announces items currently held and eligible for transfer.
- Senders MUST NOT include expired items (`now_ms >= expires_at_unix_ms`).
- Entries SHOULD be sorted by `item_id` ascending for deterministic pagination.

Versioning expectation:

- In v1, all listed fields are required.
- New fields MAY be added in future versions as optional-only extensions.

Pagination/batching behavior:

- `inventory` MAY be split across pages.
- `has_more=true` means the next page for the same `(session_id, type)` is expected at `page+1`.

### 4.2 MissingRequest (`type = missing_request`)

Required fields:

- common required fields
- `request_id`: unique per logical missing request
- `in_response_to_page`: `inventory_summary.page` this request was derived from
- `missing_item_ids`: array of requested `item_id`
- `max_transfer_items`: integer budget hint
- `max_transfer_bytes`: integer budget hint

Field semantics:

- `missing_item_ids` MUST contain only IDs observed in the session's `inventory_summary` stream.
- Receivers MUST ignore (or explicitly reject in `receipt`) IDs not present in announced inventory.
- Requesters MUST NOT request expired items.

Versioning expectation:

- `request_id` is the idempotency key for request replay handling.

Pagination/batching behavior:

- Large missing sets MAY be split across pages with stable `request_id` prefixing strategy.
- `missing_item_ids` SHOULD be sorted ascending for deterministic request chunks.

### 4.3 Transfer (`type = transfer`)

Required fields:

- common required fields
- `transfer_id`: unique per transfer frame
- `in_response_to_request_id`: corresponding `missing_request.request_id`
- `items`: array of transfer entries

Required fields per transfer entry:

- `item_id`
- `manifest_id`
- `to_wayfarer_id`
- `expires_at_unix_ms`
- `total_size_bytes`
- `chunk_size_bytes` (MUST be `32768`)
- `chunk_count`
- `envelope_b64`: base64url (no padding) canonical `EnvelopeV1` bytes

Field semantics:

- `item_id` MUST equal `hex_lower(SHA-256(base64url_decode(envelope_b64)))`.
- Decoded `envelope_b64` bytes MUST decode as canonical `EnvelopeV1`.
- `to_wayfarer_id` MUST equal `hex_lower(EnvelopeV1.toWayfarerId)` decoded from `envelope_b64`.
- Expired items MUST NOT be transferred.

Versioning expectation:

- `transfer_id` is the idempotency key for transfer replay handling.

Pagination/batching behavior:

- `items` MAY be split across pages.
- Sender SHOULD honor `max_transfer_items` and `max_transfer_bytes` from the corresponding request.

### 4.4 Receipt (`type = receipt`)

Required fields:

- common required fields
- `receipt_id`: unique per receipt frame
- `in_response_to_transfer_id`: corresponding `transfer.transfer_id`
- `status`: one of `accepted`, `partial`, `rejected`
- `accepted_item_ids`: array of `item_id`
- `rejected_items`: array of rejection entries

Required fields per rejection entry:

- `item_id`
- `code`
- `message`

Field semantics:

- `receipt` acknowledges sync transfer processing, not end-recipient delivery.
- `receipt` MUST NOT be conflated with `ReceiptV1` device/federation semantics from `docs/spec/RECEIPTS.md`.
- `status=accepted` means all transferred items for the referenced frame were accepted.
- `status=partial` means a mixed outcome.
- `status=rejected` means no items from that frame were accepted.

Versioning expectation:

- `receipt_id` is the idempotency key for receipt replay handling.

Pagination/batching behavior:

- Receipts MAY be paged when acknowledging large transfer batches.

## 5. Versioning Expectations

1. `sync_version=1` is required for this contract.
2. If `sync_version` is unsupported, receiver MUST fail fast and enter retry flow.
3. Same-version additive optional fields are allowed; receivers MUST ignore unknown optional fields.
4. Removing or changing required-field semantics requires a new sync version.

## 6. Generic Pagination and Batching Rules

1. Pages are contiguous and 1-based per `(session_id, type)`.
2. `has_more=false` marks the terminal page for that message stream.
3. Re-sent pages with same `(session_id, type, page)` MUST be semantically identical.
4. Out-of-order pages MUST be rejected for the active stream and transition to `retry_pending`.
5. Senders SHOULD cap each frame by item count and byte budget appropriate to transport constraints.

## 7. Sync Semantics (Expected Exchange)

Expected exchange sequence:

1. Peer A and Peer B establish session context and choose/accept `session_id`.
2. Peer A sends `inventory_summary` pages.
3. Peer B computes diff and sends `missing_request` pages.
4. Peer A sends `transfer` pages for requested items.
5. Peer B stores accepted items idempotently and sends `receipt` pages.
6. Peers repeat from inventory exchange as needed until no additional items are requested.

Convergence rule:

- Session is converged when both peers have no additional missing items for the active inventory view.

## 8. Idempotency, Dedupe, and Replay Rules

### 8.1 Frame-level idempotency keys

- `inventory_summary`: `(session_id, sender_wayfarer_id, page)`
- `missing_request`: `request_id`
- `transfer`: `transfer_id`
- `receipt`: `receipt_id`

If a key is repeated, replayed frame content MUST be semantically identical. Mismatch is a protocol violation and MUST transition to `retry_pending`.

### 8.2 Item-level dedupe

1. Item storage key is `item_id`.
2. If `item_id` already exists with identical bytes, receiver MUST treat transfer as successful no-op.
3. If `item_id` exists but bytes differ, receiver MUST reject that item (`code=ITEM_ID_MISMATCH`).

### 8.3 Replay handling window

1. Receivers SHOULD retain recently seen `request_id`/`transfer_id`/`receipt_id` values for at least the session lifetime.
2. Replayed valid frames in-window MUST be idempotent no-ops.
3. Stale frames from prior sessions (different `session_id`) MUST be ignored.

### 8.4 Expiry and TTL

1. Expired items (`now_ms >= expires_at_unix_ms`) MUST NOT be requested or transferred.
2. Sync exchange MUST NOT extend TTL or mutate expiry.

## 9. Transport-Neutral State Machine

States:

- `idle`
- `inventory_exchanged`
- `missing_requested`
- `transfer_in_progress`
- `converged`
- `retry_pending`

Transition summary:

| Current State | Event | Next State |
| --- | --- | --- |
| `idle` | send/receive first `inventory_summary` | `inventory_exchanged` |
| `inventory_exchanged` | send/receive non-empty `missing_request` | `missing_requested` |
| `inventory_exchanged` | both peers compute empty missing set | `converged` |
| `missing_requested` | send/receive first `transfer` page | `transfer_in_progress` |
| `transfer_in_progress` | valid `receipt` processed and more sync needed | `inventory_exchanged` |
| `transfer_in_progress` | valid `receipt` processed and no sync remaining | `converged` |
| any active state | timeout, transport failure, page/order violation, idempotency mismatch | `retry_pending` |
| `retry_pending` | retry budget and backoff allow reattempt | `idle` |

Retry expectation:

- Retry MUST use a new `session_id`.

## 10. Conformance Fixtures

- Fixture catalog and usage: `docs/migration/GOSSIP_SYNC_CONFORMANCE_FIXTURES.md`
- Machine-readable fixtures: `testdata/gossip_sync/v1/*.json`

Normative/illustrative rule:

- The v1 machine-readable fixture JSON files are normative for conformance expectations in this repository.
- Markdown examples are explanatory/illustrative and must not override this contract.
