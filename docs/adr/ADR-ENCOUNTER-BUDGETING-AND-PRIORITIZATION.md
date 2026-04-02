# ADR: Encounter Budgeting and Prioritization

- Status: Proposed
- Date: 2026-03-31

## Context

Encounter windows are the scarce resource in Aethos. The runtime already supports deterministic frame correctness, but transfer selection still needs explicit policy hooks for:

- encounter class estimation (`blink` / `short` / `durable`),
- local weighted prioritization within strict tiers,
- explicit byte/time/durability budgets,
- explainability logs for every scheduling decision,
- interruption/resume behavior that treats partial success as normal.

Without this layer, behavior drifts toward implicit FIFO semantics, hides tradeoffs, and overfits to direct-destination contacts.

## Decision

Adopt a hybrid encounter scheduler with these anchors:

1. **Encounters are primary**: policy optimizes bounded sessions, not end-to-end single-attempt delivery.
2. **Partial success is normal**: all sessions are resumable; every unit of progress is valid.
3. **Transit forwarding is valued**: endangered third-party cargo is allowed to outrank direct-only metadata in constrained windows.
4. **Eventual convergence dominates**: control/receipt/checkpoint traffic is always protected.

The scheduler is defined as:

- hard tiers (0..5) for global ordering,
- weighted scoring only within a tier,
- budget caps by time + bytes + durable-cargo ratio,
- deterministic tie-breaking and preemption behavior,
- explainability logs emitted for each decision.

Bearer neutrality clarification:

- Encounter budgeting and scheduler decisions are bearer-neutral policy logic.
- Bearer selection/switching is local orchestration only and MUST NOT change wire contract semantics.
- `policy-stop` is distinct from budget exhaustion and must be recorded as a separate local stop class.

## Tier Contract (Exact)

- tier 0: control/receipts/checkpoints/resumability
- tier 1: tiny endangered destination-relevant message items
- tier 2: tiny endangered transit items not for peer
- tier 3: manifests/metadata for larger objects
- tier 4: message bodies/small attachments
- tier 5: large media chunks

## Weighted Fields (Within Tier)

The score breakdown must include:

- replication scarcity
- delivery proximity
- expiry urgency
- size cost
- stagnation/lack of progress
- relay-ingest or durable-storage safety
- user-intent boost
- content class

## Consequences

### Positive

- Deterministic, explainable scheduling with no wire-level semantic drift.
- Better bounded-encounter outcomes: control safety first, progress second, bulk last.
- Transit forwarding can win when risk indicates it should.

### Tradeoffs / Risks

- **Starvation risk for large media** if durable caps are too strict.
- **Duplicate replication waste** if receipt coverage is incomplete.
- **Scoring opacity** without decision logs surfaced in tests and tooling.
- **Privacy leakage risk** if logs expose sensitive fields; logs must remain local-only.
- **Direct-destination overfitting** if delivery-proximity dominates; transit lanes must remain competitive.

## Mitigations

- Keep hard tier 0 protected for receipts/checkpoints.
- Emit explicit stop reasons and interruption/resume markers.
- Keep score fields local-only and avoid bearer-specific radio semantics.
- Validate with fixture-backed test lanes for blink/short/durable sessions.

## Implementation Notes

Initial integration is intentionally hook-oriented:

- `EncounterSchedulingContext` + `EncounterBudgetProfile`
- `EncounterClass` estimator
- deterministic per-item score breakdown
- durable budget enforcement by encounter class
- explainability logs in `EncounterPlan.decisionLogs`

This first pass wires into existing `Router` transfer planning without introducing new wire protocol behavior.
