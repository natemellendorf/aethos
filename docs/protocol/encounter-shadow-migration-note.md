# Encounter Scheduler v1 Shadow Migration Note

Status: audit + shadow-only comparison (no production cutover)

## Current routing audit (legacy planner behavior)

### Transfer candidate gathering

- Transfer grouping and candidate expansion happen in `Router.buildTransferCandidates(from:now:context:)` (`AethosCore/Sources/AethosCore/Routing/Router.swift`).
- Manifests are parsed first, then envelopes are attached by `manifestId`, then chunk candidates are emitted by round-robin over grouped transfers.

### Where ordering happens today

- Store read order is FIFO-like from `AethosStore.peekQueuedOutbox(limit:)` (`AethosCore/Sources/AethosCore/Store/AethosStore.swift`), using SQL `ORDER BY enqueued_at ASC, rowid ASC`.
- Encounter planner ordering:
  - hard-tier bucket order (`EncounterTier` ascending) in `Router.buildPlan(...)`;
  - intra-tier weighted score descending;
  - tie-break by `itemId` lexicographic order.
- Legacy session planner ordering:
  - fixed kind pass order in `Router.planNextSessionLegacy(...)`;
  - transfer sort by `enqueuedAt` only;
  - chunk round-robin by grouped transfer.

### Implicit FIFO

- Yes, implicit FIFO exists from store read ordering plus stable per-kind loops.
- It is partial FIFO because hard tiers and scoring can reorder candidates within encounter planning.

### Direct destination relevance dominance

- Direct relevance contributes strongly (`deliveryProximity`) but does **not** globally dominate:
  - hard tiers are absolute;
  - transit endangered tier-2 items can rank above direct tier-3 metadata.

### Receipts/checkpoints protection

- Yes, primarily protected:
  - legacy planner sends receipts/inventory requests first;
  - encounter planner places receipts/inventory requests in tier 0.
- Not mathematically absolute under impossible budgets (for example item does not fit `maxBytes`).

### Nondeterminism entry points

- Time-dependent chunk rotation seed (`chunkRotationOffset(nowMs:manifestId:count:)`) changes ordering between runs with different `now`.
- Legacy transfer tie ordering on equal `enqueuedAt` depends on dictionary value iteration before sort key tie-break.
- Encounter path reduces this by explicit secondary sort key (`manifestId`) in transfer ordering.

## Shadow-mode implementation (this bead)

- Legacy encounter plan remains authoritative.
- In debug/test builds, `EncounterSchedulerV1` runs on the **same candidate set** as legacy planning.
- Shadow output is exposed in `EncounterPlan.shadowComparison` (no wire changes, no primary selection changes).

Key code:

- `EncounterSchedulingContext.shadowMode`, `shadowTopN` and `EncounterShadowMode`.
- `EncounterShadowComparison` telemetry payload with normalized diff flags.
- `Router.buildShadowComparison(...)` runs canonical scheduler and compares against legacy selected outputs.

## Known mismatch classes captured by telemetry

- `topNChanged`
- `firstSelectedChanged`
- `stopReasonChanged`
- `tierDistributionChanged`
- `transitDirectBalanceChanged`
- `schedulerError`

## Low-risk cutover path

1. Keep production at `shadowMode = .disabled`.
2. Run debug/test suites and scenario tests, inspect `shadowComparison.differences` frequency and shape.
3. Resolve deterministic mismatch hotspots first (notably legacy transfer equal-enqueue tie handling and stop-reason semantics alignment).
4. Add guardrail threshold (for example fail CI on unexpected diff classes) before any runtime switch.
5. Introduce explicit runtime flag for canonical-primary mode only after sustained zero-regression shadow runs.
