# Replication and Store-Carry-Forward Model

Status: authoritative replication behavior for resilient gossip propagation.

## 1. Replication Strategy

Aethos uses multi-path propagation, not strict single-custody transfer.

Core behavior:

- multiple nodes may concurrently hold the same object,
- objects propagate opportunistically across encounters,
- replication continues until relay ingestion or expiry/pruning,
- node disappearance does not imply object loss if replicas exist elsewhere.

Recommended replication target: **6–8 nodes**.

## 2. Object Lifecycle

Each object carries:

- `item_id`
- `envelope_b64`
- `expiry`
- `hop_count`

Lifecycle stages:

1. **Created/ingested**: object validated and stored.
2. **Replicated**: forwarded to encountered peers.
3. **Relay-ingested (optional milestone)**: durability signal received.
4. **Pruned/expired**: removed due to policy.

## 3. Hop Count Semantics

- Forwarding node increments `hop_count` by exactly 1.
- `hop_count` is an input for local propagation policy.
- Protocol correctness does not require a global hard hop limit.

This permits adaptive replication without violating deterministic frame semantics.

## 4. Relay Ingestion Semantics

`RELAY_INGEST` frames list `item_ids` durably accepted by relay mesh.

After relay ingestion confirmation, nodes may:

- reduce replication priority,
- lower replica targets for those objects,
- prune local copies when storage pressure exists.

Objects should not be deleted solely because they were forwarded once.

## 5. Pruning Rules

Preferred retention until one or more holds:

- relay ingestion confirmed,
- object expiry reached,
- local storage pressure requires pruning.

Pruning guidance:

- prune expired first,
- then relay-ingested high-hop objects,
- preserve non-ingested objects longer to maintain delivery probability.

## 6. Propagation Horizon Concept

Propagation horizon controls replication aggressiveness as objects move farther from origin.

Inputs available to policy:

- `hop_count`
- `expiry`
- relay-ingest state

Illustrative policy:

- `hop_count` 0–2: aggressive replication,
- `hop_count` 3–5: moderate replication,
- `hop_count` >5: opportunistic replication.

This is implementation policy, not protocol-mandated behavior.

## 7. Failure Resilience

Multi-path replication protects against:

- peer disappearance before onward transfer,
- bearer instability,
- sparse or delayed encounter opportunities.

Because replicas are distributed, convergence can continue via alternate paths.

## 8. Security Considerations

- Verify `item_id` hash before store/forward.
- Reject expired/malformed objects early.
- Bound storage and transfer rates to mitigate flooding.
- Avoid policy choices that create deterministic starvation for subsets of peers.
