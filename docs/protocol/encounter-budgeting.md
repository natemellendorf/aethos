# Encounter Budgeting and Prioritization (Runtime Policy)

Status: runtime policy guidance for encounter scheduler hooks.

This document is policy-layer guidance only. It does not alter wire schema, frame validity, or acceptance semantics.

## 1) Philosophy Anchors

1. Encounters are primary.
2. Partial success is normal.
3. Transit forwarding is valued.
4. Eventual convergence is the objective.

## 2) Encounter Classes

- **blink**: extremely constrained windows; protect control and endangered tiny items.
- **short**: moderate windows; complete control + metadata and some cargo.
- **durable**: long windows; include durable cargo while preserving control guarantees.

Encounter class estimation must come from abstract session estimates (time/budget/reliability), not radio-specific semantics.

## 3) Tier Definitions (Exact)

- tier 0: control/receipts/checkpoints/resumability
- tier 1: tiny endangered destination-relevant message items
- tier 2: tiny endangered transit items not for peer
- tier 3: manifests/metadata for larger objects
- tier 4: message bodies/small attachments
- tier 5: large media chunks

## 4) Hybrid Scheduler Model

The runtime uses hybrid scheduling:

1. **Hard tiers**: never let lower tiers displace higher tiers.
2. **Weighted scoring within tier**: deterministic ranking fields:
   - replication scarcity
   - delivery proximity
   - expiry urgency
   - size cost
   - stagnation/lack of progress
   - relay-ingest or durable-storage safety
   - user-intent boost
   - content class
3. **Budget caps**:
   - bytes (`maxBytes`)
   - items (`maxItems`)
   - estimated encounter duration
   - durable-cargo ratio cap (tier 4/5 bytes)
4. **Preemption model**:
   - lower-tier planning is preemptible,
   - stop reasons are explicit,
   - interruption/resume markers indicate resumable progress.

## 5) Explainability Log Contract

Each decision log must include at least:

- encounter class
- selected bearer (or attempted bearer sequence)
- encounter attempt id (`encounterAttemptID`, local-only)
- optional bearer class label (`bearerClass`, local-only diagnostics)
- estimated time/byte budget
- candidate counts by tier
- chosen item id
- score breakdown
- `stopReason` (kebab-case canonical scheduler token from `docs/protocol/encounter-scheduler-v1.md`)
- `stopClass` (local-only rollup bucket)
- interruption/resume markers

`stopReason` MUST be one of:

- `completed`
- `policy-stop`
- `budget-items-exhausted`
- `budget-bytes-exhausted`
- `encounter-time-exhausted`
- `durable-ratio-cap-reached`
- `no-eligible-items`

`stopClass` values are local-only snake_case diagnostics and MUST be derived from `stopReason` using this mapping:

- `policy-stop` -> `policy_stop`
- `budget-items-exhausted` -> `budget_exhausted`
- `budget-bytes-exhausted` -> `budget_exhausted`
- `encounter-time-exhausted` -> `budget_exhausted`
- `durable-ratio-cap-reached` -> `budget_exhausted`
- `completed` -> `completed`
- `no-eligible-items` -> `no_eligible_items`

When multiple attempts are made, logs SHOULD retain attempt history (e.g., bearer sequence and per-attempt `stopReason`/`stopClass`) to explain local orchestration decisions.

Logs are local-only diagnostics and must not be transmitted.

For multi-bearer encounter selection/transition telemetry layering and refusal taxonomy binding, see `docs/protocol/multi-bearer-telemetry.md`. In particular, `policy_stop`/`policy-stop` remain stop/terminal classification tokens and MUST NOT be used as `refusalReason`.

## 6) Runtime Hook Surface (Initial)

- `EncounterBudgetProfile`: bytes/items/time/durable cap estimates.
- `EncounterSchedulingContext`: peer-agnostic context + optional remote destination + user intent boosts.
- `EncounterPlan`: selected cargo + per-decision explainability logs.
- `Router.planNextEncounter(context:now:)`: hook-integrated planning entry point.
- `Router.planNextSession(budget:now:)`: compatibility wrapper.

## 7) Interruption/Resume Behavior

- Metadata and chunks are marked resume-capable.
- Budget stop emits interruption marker.
- Next encounter repeats deterministic planning over remaining queue state.
- Partial completion is expected; eventual convergence is preserved.

Resume markers are bearer-agnostic local state:

- they MUST track pending protocol work by object/progress identity, not by bearer handle,
- they MAY be reused when the next encounter runs on a different bearer,
- they MUST NOT imply carry-forward of partially decoded frame bytes or skipped handshake/summary steps.

Cross-bearer resume/upgrade/downgrade transitions are subject to downgrade-resistance policy in `docs/adr/ADR-0004-multi-bearer-encounter-architecture.md`.

## 8) Risk Register

1. **Large media starvation** under tight durable-cargo caps.
2. **Duplicate replication waste** when receipts are sparse.
3. **Scoring opacity** without consistent logs/fixtures.
4. **Privacy leakage** if explainability payload is exported.
5. **Overfitting to destination contacts** if transit scoring is too weak.

## 9) Test Plan and Fixtures

Fixtures live at:

- `AethosCore/Tests/AethosCoreTests/Resources/Fixtures/encounter-budgeting/blink.json`
- `AethosCore/Tests/AethosCoreTests/Resources/Fixtures/encounter-budgeting/short.json`
- `AethosCore/Tests/AethosCoreTests/Resources/Fixtures/encounter-budgeting/durable.json`

Baseline test lanes:

1. **blink**: prioritize tier 0 + endangered tiny message/transit before bulk.
2. **short**: complete control + metadata and some tier 4 cargo.
3. **durable**: include tier 5 chunks while ensuring control remains present.
4. **transit endangered**: third-party endangered items can beat destination metadata.
5. **explainability diagnostics**: score + stop reasons + interruption markers are present.
