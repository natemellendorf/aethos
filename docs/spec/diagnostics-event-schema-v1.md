# Diagnostics Event Schema v1

Status: proposed canonical contract for cross-platform diagnostics collection.

## Purpose

Define a single structured diagnostics event contract that desktop and iOS can emit for one run-scoped encounter timeline. This contract is designed for agent consumption, not just human log reading.

## Privacy Rules

- Never send plaintext message bodies by default.
- Never send private keys, session secrets, auth tokens, or decrypted payload bodies.
- Prefer stable IDs, counters, hashes, lengths, timestamps, and protocol metadata.
- Any verbose payload capture must remain local-only and explicitly debug-gated.

## Required Fields

- `schema_version` — string, currently `diagnostics-event-schema-v1`
- `run_id` — shared identifier for one orchestrated scenario run
- `session_id` — per-process/session identifier
- `encounter_id` — encounter-scoped correlation ID; use `unknown` if no finer scope exists
- `event_id` — unique event identifier within the run
- `timestamp_utc` — RFC3339 UTC timestamp with milliseconds
- `platform` — `ios`, `linux`, `macos`, `windows`, etc.
- `app` — emitter identity such as `aethos-desktop` or `aethos-ios`
- `build_sha` — source revision or `unknown`
- `component` — subsystem such as `relay`, `protocol.lan-udp`, `ui`, `inbox`
- `event_type` — canonical event name
- `phase` — lifecycle phase such as `discovery`, `hello`, `summary`, `request`, `transfer`, `import`, `ui`
- `result` — `ok`, `started`, `ignored`, `failed`, `error`

## Optional Fields

- `peer_id`
- `remote_peer_id`
- `item_id`
- `bearer`
- `reason_code`
- `message`
- `fields` — structured JSON object for counts, timings, endpoint metadata, and monotonic sequence numbers

## Canonical Event Catalog v1

Required catalog:

- `app.start`
- `app.stop`
- `diag.run.attached`
- `discovery.started`
- `discovery.signal.detected`
- `discovery.signal.ignored`
- `bearer.selected`
- `encounter.opened`
- `encounter.closed`
- `hello.sent`
- `hello.received`
- `summary.sent`
- `summary.received`
- `request.planned`
- `request.sent`
- `request.received`
- `transfer.sent`
- `transfer.received`
- `receipt.sent`
- `receipt.received`
- `inbox.import.started`
- `inbox.import.succeeded`
- `inbox.import.failed`
- `ui.projection.started`
- `ui.projection.succeeded`
- `ui.projection.failed`
- `relay.connected`
- `relay.disconnected`
- `error`

Implementations MAY add additional names, but MUST NOT rename or redefine the canonical events above.

## Ordering

- Emitters SHOULD include a monotonic process-local sequence in `fields.sequence`.
- Consumers MUST order primarily by `timestamp_utc`, then by stable ingest order or `fields.sequence` when available.

## Retention Guidance

- Collector default retention SHOULD be time-based TTL.
- Local JSONL/rolling-file diagnostics MAY retain a shorter horizon than the central collector.
- Run artifacts SHOULD persist `timeline`, `summary`, and the run metadata bundle alongside test artifacts.

## Example

```json
{
  "schema_version": "diagnostics-event-schema-v1",
  "run_id": "run-1713700000-1234",
  "session_id": "session-1713700000123-4242",
  "encounter_id": "relay-wss://127.0.0.1:8082-peer-abc",
  "event_id": "session-1713700000123-4242-00000042",
  "timestamp_utc": "2026-04-21T20:15:12.123Z",
  "platform": "linux",
  "app": "aethos-desktop",
  "build_sha": "abc1234",
  "component": "protocol.lan-udp",
  "event_type": "transfer.received",
  "phase": "transfer",
  "result": "ok",
  "peer_id": "127.0.0.1:58656",
  "item_id": "8f...",
  "bearer": "lan-udp",
  "fields": {
    "sequence": 42,
    "bytes": 2048,
    "transport": "lan-udp"
  }
}
```

## Summary Semantics

Collector-side summaries SHOULD report:

- highest protocol phase reached for the run
- per-item highest phase reached
- sent and received item IDs
- missing transitions
- top errors grouped by `reason_code`
- stall points such as:
  - discovery without encounter
  - hello without summary
  - request without transfer
  - transfer without import
  - import without UI projection
