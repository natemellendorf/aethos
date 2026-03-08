# GOSSIP_SYNC_V1 Conformance Fixtures

Status: Canonical v1 fixture catalog

This document defines canonical conformance fixtures for `docs/spec/GOSSIP_SYNC_V1.md`.

## 1. Normative Scope

- Normative message contract: `docs/spec/GOSSIP_SYNC_V1.md`
- Normative machine-readable fixtures: `testdata/gossip_sync/v1/*.json`
- This markdown file is normative for fixture selection and interpretation rules.
- Any inline examples in this file are illustrative unless they point to a fixture file.

## 2. Fixture Format

Current canonical fixture format is JSON object form.

- JSON keys are snake_case and match the sync contract field names.
- `envelope_b64` uses base64url without padding and carries canonical `EnvelopeV1` bytes.
- `item_id` values are SHA-256 hashes of decoded `envelope_b64` bytes.

Future optional fixture representations:

- CBOR hex fixtures MAY be added later as supplementary files.
- If both JSON and CBOR are present for the same fixture, JSON remains normative unless this file is updated to state otherwise.

## 3. Canonical Fixture Set (v1)

### 3.1 Single-message fixtures

1. `testdata/gossip_sync/v1/inventory_summary.page1.json`
   - Canonical `inventory_summary` page with two items.
2. `testdata/gossip_sync/v1/missing_request.page1.json`
   - Canonical `missing_request` requesting one missing item.
3. `testdata/gossip_sync/v1/transfer.page1.json`
   - Canonical `transfer` carrying one requested item.
4. `testdata/gossip_sync/v1/receipt.page1.json`
   - Canonical `receipt` for accepted transfer.

### 3.2 Transcript fixture

5. `testdata/gossip_sync/v1/happy_path.transcript.json`
   - Full happy-path exchange transcript referencing the four single-message fixtures.
   - Documents sender/receiver and expected state machine progression.

## 4. Illustrative Payload Excerpts

The following excerpts are illustrative summaries; use fixture files as normative data.

`InventorySummary` excerpt:

```json
{ "type": "inventory_summary", "sync_version": 1, "page": 1, "has_more": false, "inventory": [{ "item_id": "...", "chunk_size_bytes": 32768 }] }
```

`MissingRequest` excerpt:

```json
{ "type": "missing_request", "sync_version": 1, "request_id": "req-...", "missing_item_ids": ["..."] }
```

`Transfer` excerpt:

```json
{ "type": "transfer", "sync_version": 1, "transfer_id": "xfer-...", "items": [{ "item_id": "...", "envelope_b64": "..." }] }
```

`Receipt` excerpt:

```json
{ "type": "receipt", "sync_version": 1, "receipt_id": "rcpt-...", "status": "accepted", "accepted_item_ids": ["..."] }
```

Happy-path transcript excerpt:

```json
{ "name": "gossip_sync_v1_happy_path_single_page", "steps": [{ "step": 1, "fixture": "inventory_summary.page1.json" }, { "step": 2, "fixture": "missing_request.page1.json" }, { "step": 3, "fixture": "transfer.page1.json" }, { "step": 4, "fixture": "receipt.page1.json" }] }
```

## 5. Canonical Happy-Path Exchange

Expected order for the transcript fixture:

1. `inventory_summary.page1.json`
2. `missing_request.page1.json`
3. `transfer.page1.json`
4. `receipt.page1.json`

Expected state progression:

- `idle` -> `inventory_exchanged` -> `missing_requested` -> `transfer_in_progress` -> `converged`

## 6. Validation Guidance

Implementations validating these fixtures SHOULD verify:

1. Required fields and type values match `GOSSIP_SYNC_V1` exactly.
2. `sync_version == 1` for all fixture messages.
3. `chunk_size_bytes == 32768` for all transfer/inventory entries.
4. `item_id == hex_lower(SHA-256(base64url_decode(envelope_b64)))` in transfer fixtures.
5. Transcript step ordering and expected state transitions are honored.

## 7. Notes for Conformance Authors

- Use these fixtures as baseline positive-path conformance vectors.
- Negative/error-path vectors (replay mismatch, expired item transfer, page-order violation) SHOULD be added as separate fixture files in future beads.
