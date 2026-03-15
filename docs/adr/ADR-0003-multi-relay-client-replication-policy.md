# ADR-0003: Multi-relay client replication policy

- Status: Proposed
- Date: 2026-03-15

## Context

Gossip V1 is an object-reconciliation protocol where propagation can occur across many paths and many participants. In this model, seeing the same object from multiple relays is valid and expected behavior, not a protocol fault.

Existing protocol docs already define the correctness constraints for reconciliation, deduplication, and encounter behavior:

- Runtime architecture and role symmetry: [ADR-0002](./ADR-0002-runtime-architecture-gossip-v1.md)
- Gossip invariants and relay ingest trust requirements: [`docs/protocol/gossip.md`](../protocol/gossip.md)
- Replication and pruning safety model: [`docs/protocol/replication.md`](../protocol/replication.md)
- Encounter/session behavior: [`docs/protocol/encounter.md`](../protocol/encounter.md)
- Canonical wire contracts: [`docs/spec/*`](../spec)

What is missing is explicit client policy guidance for operating across multiple relays without drifting into blind flooding behavior.

## Decision drivers

- Resilience during partial outages and relay churn
- Better delivery reachability under partitioned network conditions
- Predictable client resource usage (bandwidth, battery, storage)
- Operator diversity and reduced single-relay dependency
- Privacy/control through client-side policy choices
- Interoperability without changing Gossip V1 wire correctness

## Decision

### 1) Multi-relay propagation is valid and expected

Clients MAY concurrently replicate eligible objects through multiple relays. Receiving duplicate deliveries from different relays is normal in a multi-path system.

### 2) Deduplication is by `item_id`

Clients and relays MUST treat `item_id` as the canonical identity key and perform idempotent deduplication by `item_id` only.

### 3) Healthy redundancy, not blind flooding

Redundancy is a reliability mechanism and SHOULD be intentional:

- Use bounded fan-out and encounter budgets.
- Prefer policy-driven relay selection over broadcast-to-all behavior.
- Preserve protocol validity semantics; policy choices only affect preference and scheduling.

Blind flooding (unbounded replication to every available relay/peer) is explicitly discouraged.

### 4) Relay classes are policy categories, not protocol roles

"Relay classes" (for example: trusted/private, public/community, managed/commercial) are local policy categories used for selection and weighting. They are not wire-level roles and do not change protocol semantics.

### 5) Recommended client policy (non-normative guidance)

For each eligible outbound object, clients SHOULD:

1. Start with a small, diverse relay set (typically 2-3 classes/operators when available).
2. Apply bounded initial fan-out, then adapt based on evidence.
3. Prioritize relays with recent success for the destination cohort.
4. Keep per-item attempt state keyed by `item_id`.
5. Continue opportunistic replication across encounters until de-escalation conditions are met.

This is policy guidance only and does not introduce wire/protocol changes.

### 6) De-escalation evidence signals

Clients MAY reduce replication intensity for an item only when there is evidence, such as:

- authenticated relay-ingest durability signals consistent with protocol guidance,
- repeated independent path observations of the same `item_id`,
- approaching expiry or local storage-pressure policy triggers.

Unauthenticated signals MUST NOT be used as sole justification for pruning or replication de-escalation.

### 7) Example scenario

A client originates object `X` and offers it to Relay A and Relay B. Relay A is temporarily partitioned from some recipients; Relay B remains reachable. The object is still discoverable through Relay B encounters, and later reconverges through Relay A after partition recovery. Duplicate receptions are ignored by `item_id` deduplication, so redundancy improves liveness without violating correctness.

### 8) Monetization note

Relay operators may expose service tiers or differentiated operating policies, and clients may account for those in local relay-class weighting. This ADR does not define pricing, billing, or commercial terms.

## Consequences

- Clarifies that multi-relay duplicate propagation is expected behavior in Gossip V1.
- Aligns client behavior with idempotent reconciliation and dedup-by-`item_id` invariants.
- Encourages resilience through bounded, evidence-driven redundancy.
- Prevents policy categories from being mistaken as protocol-level role changes.

## Non-goals

- No changes to frame formats, encounter order, or validation rules.
- No new receipt or relay-wire semantics.
- No relay product/SLA standardization.
- No pricing or billing specification.
