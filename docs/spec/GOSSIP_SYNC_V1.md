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
5. `inventory_summary` data reveals local inventory and MUST NOT be sent to unauthenticated peers.
6. Inventory eligibility and authorization policy is deployment-specific, but implementations MUST enforce it before emitting `inventory_summary`.

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
- `manifest_id`: lowercase hex, exactly 64 chars; MUST equal `hex_lower(SHA-256(canonical_manifest_v1_bytes))`, where `canonical_manifest_v1_bytes` is `ManifestV1` encoded exactly as `Canonical Bytes v1` in `docs/protocol.md`.
- `sync_version`: integer, MUST be `1` for this contract.
- `session_id`: opaque string identifier unique per sync attempt between a peer pair.
- `page`: integer, 1-based.
- `has_more`: boolean.
- `chunk_size_bytes`: integer, MUST be `32768`.
- `expires_at_unix_ms`: integer (`UInt64`) Unix epoch milliseconds.
- `total_size_bytes`: integer, semantic size from `ManifestV1.totalSize` (payload/body bytes, not envelope byte length).
- `chunk_count`: integer, semantic chunk count from `ManifestV1.chunkIds.count`.

Chunk metadata and transfer model:

1. v1 does NOT define chunk payload frames.
2. `transfer.items[].envelope_b64` always carries full canonical `EnvelopeV1` bytes.
3. `total_size_bytes`, `chunk_size_bytes`, and `chunk_count` are manifest metadata values associated with `manifest_id` and MUST be consistent between `inventory_summary` and `transfer` for the same `item_id`.

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
- Inventory stream key is `(session_id, sender_wayfarer_id)`.
- `has_more=true` means the next page for the same inventory stream key is expected at `page+1`.

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
- Receivers MUST ignore `missing_item_ids` that were not announced in `inventory_summary` for the active session.
- Requesters MUST NOT request expired items.
- If requester computes an empty missing set, it MUST still send `missing_request` with `missing_item_ids=[]`, `page=1`, and `has_more=false` for that logical request.

Versioning expectation:

- `request_id` identifies one logical missing-request stream and participates in page-level idempotency keys (`(stream_key, page)`).

Pagination/batching behavior:

- Large missing sets MAY be split across pages.
- All pages for one logical request MUST use the same `request_id`.
- Missing-request stream key is `(session_id, request_id)`.
- `has_more=true` means the next page for the same missing-request stream key is expected at `page+1`.
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

- `transfer_id` identifies one logical transfer stream and participates in page-level idempotency keys (`(stream_key, page)`).

Pagination/batching behavior:

- `items` MAY be split across pages.
- Transfer stream key is `(session_id, transfer_id)`.
- `has_more=true` means the next page for the same transfer stream key is expected at `page+1`.
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
- `receipt` is a sync receipt and MUST NOT be conflated with `ReceiptV1` device/federation semantics from `docs/spec/RECEIPTS.md`.
- `status=accepted` means all transferred items for the referenced frame were accepted.
- `status=partial` means a mixed outcome where some transfer items were accepted and some were rejected.
- `status=rejected` means no items from that frame were accepted.
- Let `transfer_item_ids` be the set of item IDs from the referenced transfer stream.
- `accepted_item_ids` and `rejected_items[].item_id` MUST each be subsets of `transfer_item_ids`.
- `accepted_item_ids` and `rejected_items[].item_id` MUST be disjoint.
- Duplicate IDs in either set are not allowed.
- `status=accepted`: `accepted_item_ids` MUST equal `transfer_item_ids`, and `rejected_items` MUST be empty.
- `status=rejected`: `accepted_item_ids` MUST be empty, and `rejected_items[].item_id` MUST equal `transfer_item_ids`.
- `status=partial`: both accepted and rejected sets MUST be non-empty, and their union MUST equal `transfer_item_ids`.

Versioning expectation:

- `receipt_id` identifies one logical receipt stream and participates in page-level idempotency keys (`(stream_key, page)`).

Pagination/batching behavior:

- Receipts MAY be paged when acknowledging large transfer batches.
- Receipt stream key is `(session_id, receipt_id)`.
- `has_more=true` means the next page for the same receipt stream key is expected at `page+1`.

## 5. Versioning Expectations

1. `sync_version=1` is required for this contract.
2. If `sync_version` is unsupported, receiver MUST fail fast and enter retry flow.
3. Same-version additive optional fields are allowed; receivers MUST ignore unknown optional fields.
4. Removing or changing required-field semantics requires a new sync version.

## 6. Stream-Scoped Pagination, Ordering, and Session Rules

### 6.1 Stream keys

Pagination is scoped by logical stream key, not only by message type.

- `inventory_summary` stream key: `(session_id, sender_wayfarer_id)` (equivalently `(session_id, type, sender_wayfarer_id)` because `type` is fixed for this stream)
- `missing_request` stream key: `(session_id, request_id)`
- `transfer` stream key: `(session_id, transfer_id)`
- `receipt` stream key: `(session_id, receipt_id)`

### 6.2 Page ordering and replay

1. Pages are contiguous and 1-based within each stream key.
2. `has_more=false` marks terminal page for that stream key.
3. Idempotency key is `(stream_key, page)`.
4. Replayed frame with same idempotency key MUST be semantically identical.
5. Out-of-order or gap page numbers for the active stream key MUST be ignored and MUST transition session state to `retry_pending`.
6. Senders SHOULD cap each frame by item count and byte budget appropriate to transport constraints.

### 6.3 Session establishment and collisions

1. Session initiator chooses `session_id` and sends the first `inventory_summary`.
2. Responder MUST echo that `session_id` in all response frames for the active session.
3. Frames with unknown or non-active `session_id` MUST be ignored and MUST transition local state to `retry_pending`.
4. Multiple concurrent sessions MUST NOT be interleaved on one peer connection.
5. If both peers initiate conflicting active sessions on the same connection, both sides MUST transition to `retry_pending` and restart with backoff using a new `session_id`.

## 7. Sync Semantics (Expected Exchange)

Expected exchange sequence:

1. Peer A (initiator) chooses `session_id`; Peer B accepts it by echoing the same `session_id`.
2. Peer A sends `inventory_summary` pages.
3. Peer B computes diff and sends `missing_request` pages.
4. If Peer B has no missing items, Peer B MUST still send `missing_request` with `missing_item_ids=[]`, `page=1`, and `has_more=false`.
5. Peer A sends `transfer` pages for requested items.
6. Peer B stores accepted items idempotently and sends `receipt` pages.
7. Peers repeat from inventory exchange as needed until an empty missing request is exchanged and accepted.

Convergence rule:

- Session is converged when an empty `missing_request` (`missing_item_ids=[]`, `page=1`, `has_more=false`) is exchanged for the active inventory view.

## 8. Idempotency, Dedupe, and Replay Rules

### 8.1 Frame-level idempotency keys

- Frame idempotency key is `(stream_key, page)` as defined in Section 6.
- If a key is repeated, replayed frame content MUST be semantically identical.
- If repeated key content differs, receiver MUST treat it as protocol violation and transition to `retry_pending`.

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
| `inventory_exchanged` | send/receive empty `missing_request` (`missing_item_ids=[]`, `page=1`, `has_more=false`) | `converged` |
| `missing_requested` | send/receive first `transfer` page | `transfer_in_progress` |
| `transfer_in_progress` | valid `receipt` processed | `inventory_exchanged` |
| any active state | timeout, transport failure, unknown/non-active session frame, page/order violation, idempotency mismatch | `retry_pending` |
| `retry_pending` | retry budget and backoff allow reattempt | `idle` |

Retry expectation:

- Retry MUST use a new `session_id`.

## 10. Conformance Fixtures

- Fixture catalog and usage: `docs/migration/GOSSIP_SYNC_CONFORMANCE_FIXTURES.md`
- Machine-readable fixtures: `testdata/gossip_sync/v1/*.json`

Normative/illustrative rule:

- The single-message v1 fixtures (`inventory_summary.page1.json`, `missing_request.page1.json`, `transfer.page1.json`, `receipt.page1.json`, `missing_request.empty.page1.json`) are normative for conformance expectations in this repository.
- Transcript fixtures are informative scenario aids and are not normative contract vectors.
- Markdown examples are explanatory/illustrative and must not override this contract.
