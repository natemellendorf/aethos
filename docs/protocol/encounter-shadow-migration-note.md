# Encounter Scheduler v1 Shadow Migration Note

Status: canonical cutover complete (Encounter Scheduler v1 is primary)

## Current routing audit (canonical primary behavior)

### Transfer candidate gathering

- Transfer grouping and candidate expansion happen in `Router.buildTransferCandidates(from:now:context:)` (`AethosCore/Sources/AethosCore/Routing/Router.swift`).
- Manifests are parsed first, then envelopes are attached by `manifestId`, then chunk candidates are emitted by round-robin over grouped transfers.

### Where ordering happens today

- Store read order is FIFO-like from `AethosStore.peekQueuedOutbox(limit:)` (`AethosCore/Sources/AethosCore/Store/AethosStore.swift`), using SQL `ORDER BY enqueued_at ASC, rowid ASC`.
- Canonical planner ordering:
  - hard-tier ordering, deterministic score ordering, and tie-break behavior in `EncounterSchedulerV1`;
  - canonical selection is projected back into `EncounterPlan.items` + explainability logs by `Router.buildCanonicalPlan(...)`.
- Session planning (`Router.planNextSession`) delegates to canonical encounter planning with session-compatible defaults.
- Legacy weighted-order implementation is now isolated to `Router.buildLegacyFallbackPlan(...)` and used only for DEBUG shadow telemetry.

### Implicit FIFO

- Input candidate collection still starts from store FIFO-like ordering.
- Final selection ordering is canonical scheduler output (deterministic, score/tie-break driven), not FIFO.

### Direct destination relevance dominance

- Direct relevance contributes strongly (`deliveryProximity`) but does **not** globally dominate:
  - hard tiers are absolute;
  - transit endangered tier-2 items can rank above direct tier-3 metadata.

### Receipts/checkpoints protection

- Yes, protected via canonical tiering:
  - receipts/inventory requests remain tier 0 and are favored by canonical ranking/selection.
- Not mathematically absolute under impossible budgets (for example item does not fit `maxBytes`).

### Nondeterminism entry points

- Time-dependent chunk rotation seed (`chunkRotationOffset(nowMs:manifestId:count:)`) remains intentional and affects candidate ordering across different `now` inputs.
- Canonical scheduling itself is deterministic for the same input set.

## Shadow-mode implementation (post-cutover)

- Canonical encounter plan is authoritative in all production builds.
- In debug/test builds, legacy fallback planning can be compared against canonical output using `EncounterShadowMode.compareLegacyFallbackV1`.
- Shadow output remains exposed in `EncounterPlan.shadowComparison` (no wire or frame changes).

Key code:

- `EncounterSchedulingContext.shadowMode`, `shadowTopN` and `EncounterShadowMode`.
- `EncounterShadowComparison` telemetry payload with normalized diff flags.
- `Router.buildCanonicalPlan(...)` maps canonical scheduler output to router items + decision logs.
- `Router.buildShadowComparison(...)` compares canonical primary outputs against legacy fallback outputs.

## Known mismatch classes captured by telemetry

- `topNChanged`
- `firstSelectedChanged`
- `stopReasonChanged`
- `tierDistributionChanged`
- `transitDirectBalanceChanged`
- `selectedItemMappingLoss`
- `schedulerError` (reserved; not expected on canonical primary path)

## Post-cutover verification notes

1. Keep production default at `shadowMode = .disabled`.
2. Use DEBUG `compareLegacyFallbackV1` only for temporary telemetry while retiring legacy assumptions in tests/consumers.
3. Remove legacy fallback path once shadow telemetry is no longer needed.
