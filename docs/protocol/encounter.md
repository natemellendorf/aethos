# Encounter Lifecycle and Multi-Bearer Behavior

Status: authoritative guidance for peer encounters under the transport-neutral gossip protocol.

## 1. Encounter Model

An encounter is a temporary communication opportunity between two nodes over any supported bearer. Encounter behavior is protocol-consistent regardless of whether connectivity is LAN mDNS, relay-assisted, or future bearers such as BLE.

Encounter goals:

- quickly determine compatibility and limits,
- efficiently estimate divergence,
- exchange missing objects with bounded transfer budgets,
- preserve message durability via store-carry-forward.

## 2. Encounter State Machine

1. **Discovery**: transport advertises or discovers peer.
2. **Handshake** (`HELLO`): peers exchange protocol version, identity descriptors, and budget hints.
3. **Summary Exchange** (`SUMMARY`): peers exchange Bloom-based inventory summaries.
4. **Demand Selection** (`REQUEST`): each side requests missing `item_id`s.
5. **Object Delivery** (`TRANSFER`): sender transmits bounded object batches.
6. **Acceptance Ack** (`RECEIPT`): receiver confirms accepted objects.
7. **Durability Signal** (`RELAY_INGEST`, optional): relay durability info updates replication decisions.

The state machine may repeat steps 3–6 within a single encounter when budgets and link quality permit.

## 3. HELLO Contract and Session Parameters

HELLO fields:

- `version`: must match `GOSSIP_VERSION`.
- `node_id`: stable node identity reference.
- `node_pubkey`: cryptographic key material for future/local trust and scoring policy.
- `capabilities`: role and transport support hints.
- `propagation_class`: local propagation policy class announcement.
- `max_want`: max requested IDs accepted in one request.
- `max_transfer`: max transfer objects/bytes accepted from peer.

Session behavior:

- If version mismatch occurs, peers end encounter gracefully.
- Budget hints bound request/transfer planning.
- HELLO fields are metadata, not authorization-by-themselves.

## 4. Bloom Summary Exchange

SUMMARY fields:

- `bloom_filter`
- `item_count`

Recommended parameters:

- Bloom filter bytes: 2048
- Hash functions: 4
- False positive rate: ~1%

Design properties:

- O(1) summary size relative to large stores,
- low encounter startup overhead,
- acceptable false positives (they may suppress some requests, but future encounters recover missing objects).

## 5. Demand and Transfer Budgeting

REQUEST contains `want: [item_id]` chosen by local diffing against peer Bloom summary.

Bounded transfer expectations:

- `MAX_TRANSFER_ITEMS = 32`
- `MAX_TRANSFER_BYTES = 524288`

Operational guidance:

- prioritize unexpired objects,
- prioritize lower-hop and not-yet-relay-ingested objects when under pressure,
- split large wants into deterministic batches.

## 6. Error Handling and Retry

Encounter resilience rules:

- frame decode/validation errors are scoped to current encounter,
- invalid objects are rejected and not persisted,
- partial completion is acceptable; later encounters continue convergence,
- no single encounter is treated as exclusive custody transfer.

This preserves liveness under intermittent connectivity and peer churn.

## 7. Cross-Platform Compatibility Guidance

To keep Linux and iOS behavior compatible:

1. Share canonical CBOR schema and validation rules.
2. Use identical hash derivation and byte normalization.
3. Keep Bloom parameter constants aligned.
4. Keep hop-count increment and expiry checks deterministic.
5. Ensure transport adapters are thin wrappers around the same protocol engine.

## 8. Security Considerations

- Authenticate and validate frame structure before acting.
- Rate-limit encounter attempts and malformed frame sources.
- Do not couple trust to bearer-specific metadata.
- Keep peer scoring local-only; never transmit scores or trust labels.
