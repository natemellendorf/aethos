# Gossip Protocol Architecture (Transport-Neutral, Multi-Bearer)

Status: authoritative architecture for encounter gossip behavior in Aethos MVP0.

## 1. Purpose

This document defines the transport-neutral gossip protocol used for resilient message propagation across opportunistic encounters. The protocol:

- decouples protocol semantics from bearer implementation,
- supports multi-path store-carry-forward replication,
- scales inventory synchronization using Bloom summaries,
- includes relay-ingestion-aware pruning signals,
- provides deterministic behavior across Linux and iOS.

## 2. Scope and Invariants

### 2.1 Scope

This architecture applies to client/client and client/relay encounter sync where peers exchange gossip frames and object data.

### 2.2 Frozen MVP0 invariants

- Encoding: CBOR.
- `item_id` derivation: `SHA256(envelope_bytes)`.
- Signature family: Ed25519 (inside envelope/authenticated payload model).
- Fixed chunk size metadata for v1-compatible payloads: 32768 bytes.
- `toWayfarerId` remains visible in envelope data.

### 2.3 Safety invariants

1. Envelope bytes are immutable in transport.
2. Sender identity must come from authenticated envelope data, never transport metadata.
3. Gossip correctness must not depend on scoring or reputation policy.
4. Transport details must not alter frame meaning.

## 3. Frame Set

Protocol frames:

- `HELLO`
- `SUMMARY`
- `REQUEST`
- `TRANSFER`
- `RECEIPT`
- `RELAY_INGEST`

### 3.1 HELLO

```cbor
{
  version,
  node_id,
  node_pubkey,
  capabilities,
  propagation_class,
  max_want,
  max_transfer
}
```

Semantics:

- Establishes protocol compatibility and per-peer limits.
- Announces capability hints used for local policy selection.
- Carries fields required for future local scoring inputs.

### 3.2 SUMMARY

```cbor
{
  bloom_filter,
  item_count
}
```

Semantics:

- Compact inventory summary to avoid large explicit inventory lists.
- `item_count` supports sanity checks and false-positive interpretation.

### 3.3 REQUEST

```cbor
{
  want: [ item_id ]
}
```

Semantics:

- Requests a bounded set of missing objects.
- Requesting peer must enforce `max_want` and local resource constraints.

### 3.4 TRANSFER

```cbor
{
  objects: [
    {
      item_id,
      envelope_b64,
      expiry,
      hop_count
    }
  ]
}
```

Semantics:

- Transfers immutable object payloads plus propagation metadata.
- Sender must ensure `item_id == SHA256(base64_decode(envelope_b64))`.
- `hop_count` represents propagation distance and is incremented on forward.

### 3.5 RECEIPT

```cbor
{
  received: [ item_id ]
}
```

Semantics:

- Confirms object acceptance at the sync layer.
- Not an end-recipient delivery receipt.

### 3.6 RELAY_INGEST

```cbor
{
  item_ids: [ item_id ]
}
```

Semantics:

- Signals relay mesh durability for listed objects.
- Enables replication de-escalation/pruning policy.

## 4. Gossip Object Definition

Each gossip object contains:

- `item_id`
- `envelope_b64`
- `expiry`
- `hop_count`

Rules:

1. `item_id` MUST equal `SHA256(envelope_bytes)`.
2. Envelope bytes MUST be forwarded unchanged.
3. Expired objects MUST NOT be forwarded.
4. `hop_count` increments by 1 each forward operation.

## 5. Synchronization Flow

Nominal exchange:

1. `HELLO`
2. `SUMMARY`
3. `REQUEST`
4. `TRANSFER`
5. `RECEIPT`

Operational notes:

- Bloom summaries are compared locally to estimate missing objects.
- Request sets should be bounded by `max_want`, `MAX_TRANSFER_ITEMS`, and `MAX_TRANSFER_BYTES`.
- Repeated encounters continue convergence with idempotent object handling.

## 6. Transport Abstraction

The protocol is independent from discovery and delivery mechanics.

Transport interface concept:

```rust
trait GossipTransport {
  fn start();
  fn discover_peers();
  fn send_frame(peer, frame);
  fn receive_frame();
}
```

Current transport implementations:

- `lan_mdns_transport`
- `relay_transport`

Planned transports:

- `ble_transport`
- `direct_peer_transport`

## 7. Protocol Constants (v1 profile)

- `GOSSIP_VERSION = 1`
- `GOSSIP_PORT = 47655`
- `SERVICE_NAME = _aethos._udp.local`
- `MAX_TRANSFER_ITEMS = 32`
- `MAX_TRANSFER_BYTES = 524288`
- `BLOOM_FILTER_BYTES = 2048`
- `BLOOM_HASH_COUNT = 4`

## 8. Implementation Guidance

1. Keep protocol state machine and transport adapters in separate modules.
2. Use a shared, canonical frame codec for Linux and iOS.
3. Enforce immutable envelope validation before store/write.
4. Record `hop_count`, `expiry`, and relay-ingest flags in object metadata.
5. Treat repeated object arrivals as idempotent upserts.

## 9. Security Considerations

- Authenticate envelope data before trust/use.
- Reject object/frame size violations.
- Reject malformed `item_id` / envelope hash mismatches.
- Limit per-peer request and transfer volume to reduce abuse.
- Never infer sender identity from IP/transport identity alone.
- Preserve deterministic acceptance/rejection independent of score.
