# Replication and Store-Carry-Forward Model

Status: authoritative replication contract for resilient gossip propagation.

## 1. Normative language

RFC 2119 terms are normative.

## 2. Replication model

Aethos uses multi-path replication, not strict custody transfer.

1. Multiple nodes MAY hold same `item_id` concurrently.
2. Replication SHOULD target 6–8 nodes when feasible.
3. Forwarded-once MUST NOT imply safe deletion.
4. Node disappearance MUST NOT be assumed safe for delivery.

## 3. Hop-count monotonic behavior

1. Origin-created object MUST start with `hop_count = 0`.
2. Forwarding node MUST increment `hop_count` by exactly 1.
3. `hop_count` MUST NOT regress for same `item_id`.
4. Receiver MUST reject negative, malformed, or overflow values.
5. Receiver MUST reject same `item_id` if incoming hop is lower than stored hop.

## 4. Pruning safety requirements

Nodes MUST retain objects unless at least one safety condition holds:

1. verified expiry reached,
2. authenticated relay-ingest durability confirmed,
3. local storage pressure policy requires pruning.

Pruning order SHOULD prioritize:

- expired objects,
- relay-ingested objects with high hop_count,
- least-recently-useful objects under pressure.

## 5. Relay-ingest authentication dependency

1. RELAY_INGEST MUST be authenticated before any pruning or replication de-escalation.
2. Unauthenticated RELAY_INGEST MUST be ignored for durability decisions.
3. Relay emit behavior SHOULD occur only after durable write completion.
4. RELAY_INGEST handling MUST be idempotent by `item_id`.

## 6. Propagation horizon policy boundary

Propagation horizon is local policy only, not wire behavior.

Policy inputs MAY include:

- `hop_count`,
- `expiry`,
- relay-ingest state.

Policy outputs MUST NOT change wire validity semantics.

## 7. Failure resilience expectations

1. Partial transfer completion is acceptable.
2. Repeated encounters MUST continue convergence idempotently by `item_id`.
3. Alternate paths SHOULD preserve liveness during bearer churn.

## 8. Security considerations

- Never mutate envelope bytes during forwarding.
- Always verify `item_id` hash before store/forward.
- Enforce transfer/storage budgets against flooding pressure.
