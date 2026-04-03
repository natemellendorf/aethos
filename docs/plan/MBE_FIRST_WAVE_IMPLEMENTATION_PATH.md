# MBE First-wave Implementation Path (Downstream-ready, Not Platform-locked)

- Status: Proposed
- Date: 2026-04-03
- Bead: aethos-3ka.14
- Audience: AethosCore maintainers and downstream platform implementers (iOS / Linux / other)

This document describes the **first-wave** implementation plan for the Multi-Bearer Encounter (MBE) architecture in a way that is:
- **Downstream-ready**: downstreams can begin implementing CLAs and integrating orchestration without waiting for “final form” APIs.
- **Not platform-locked**: the first wave lives primarily in `AethosCore`, with platform-specific work limited to CLA adapters and wiring.

It ties together:
- ADR-0004 invariants (authority/layering + downgrade-resistance vocabulary)
- telemetry contract (3-lane attribution + sequencing)
- capability model v1 (timeScope preflight + refusal ordering)
- encounter lifecycle (EncounterContext / instance / attempt scoping)
- scheduler/budgeting explainability (stopReason/stopClass + terminal mapping)
- fixture suite gates (MixedBearerFixtureRunnerTests as conformance)

## Normative anchors (source-of-truth links)

This plan does not redefine contracts. It composes the existing ones:

- Architecture invariants and refusal ordering:
  - `docs/adr/ADR-0004-multi-bearer-encounter-architecture.md`
- Capability-set model and deterministic `timeScope` refusal behavior:
  - `docs/protocol/bearer-capability-model-v1.md`
- Encounter lifecycle model, terminal outcomes, transition intents:
  - `docs/protocol/encounter.md`
- Scheduler behavior and budgeting explainability:
  - `docs/protocol/encounter-scheduler-v1.md`
  - `docs/protocol/encounter-budgeting.md`
- Multi-bearer telemetry layering/sequencing and refusal taxonomy:
  - `docs/protocol/multi-bearer-telemetry.md`
- Fixture-driven conformance runner (implemented in AethosCore tests):
  - `AethosCore/Tests/AethosCoreTests/MixedBearerFixtureRunnerTests.swift`

---

## 1) Definition: “first-wave” (what counts, what doesn’t)

### 1.1 What “first-wave” means

**First-wave** is the minimum implementation slice that:
1. Preserves ADR-0004’s *encounter-first* authority and layering invariants.
2. Produces deterministic, fixture-checkable telemetry and refusal behavior.
3. Allows downstreams to build **platform-specific CLAs** without requiring platform details inside AethosCore.
4. Establishes a stable “decision loop skeleton” for selection and transitions, even if transfer/resume semantics are initially conservative.

It is explicitly **downstream-ready**: the core types and contracts are in place, and downstreams can begin integration behind gates.

### 1.2 What is implementable now in AethosCore vs platform-specific

**Implement now in `AethosCore` (first-wave core):**
- `EncounterContext` runtime skeleton (durable state + orchestration loop boundaries)
- CLA registry + snapshotting (capability snapshots and event streams)
- Selection evaluation + transition decision loop orchestration (policy-driven; deterministic ordering; refusal mapping)
- Telemetry sequencing rules (3-lane attribution; monotonic `eventSequence` per attempt; refusal/timeScope coherence)
- Fixture-driven conformance gates (MixedBearer suite runner as “must pass”)

**Implement downstream (platform-specific):**
- Concrete CLAs (Convergence Layer Adapters / transport adapters) that:
  - surface `currentCapabilitySnapshot(nowUnixMs:)`
  - emit `sessionEvents()` (opportunity discovered/lost; session opened/closed; interruption observed)
- Platform scheduling of “tick” / async orchestration execution (threading/executors)
- Real transport sessions and I/O (networking frameworks, sockets, radio stacks)
- Persistence backend choices (how durable state is stored), provided the state model is respected

**Not required for first-wave (deferred):**
- Full cross-bearer transfer/resume semantics with strong progress continuity guarantees (requires interface expansion; see Risk section)
- Real-time multipath or parallel session coordination
- Platform-specific radios (e.g., BLE), relays, or OS background execution policies

---

## 2) Goals, non-goals, and scope boundaries

### 2.1 Goals (what first-wave must deliver)

By the end of first-wave, we must have:

1. **AethosCore orchestration contract is usable by downstreams**
   - A downstream can register multiple CLAs and observe deterministic selection decisions and telemetry emission.

2. **Decision determinism and explainability are testable**
   - Refusal reasons and timeScope evaluation match the capability model + ADR-0004 ordering requirements.
   - Telemetry events are correctly attributed to lanes (`encounter`, `forwarding`, `admin_record`) and properly sequenced.

3. **Encounter lifecycle integrity**
   - A bearer-scoped encounter instance remains on one bearer.
   - Bearer switching is modeled as ending one instance and creating another (per `docs/protocol/encounter.md`).

4. **Fixture-driven gates**
   - `MixedBearerFixtureRunnerTests` is the conformance gate for the telemetry + refusal invariants it encodes.

### 2.2 Non-goals (explicitly out-of-scope for first-wave)

- No new wire protocol fields.
- No platform framework dependencies inside `AethosCore`.
- No promise of “true resume” continuity across bearers beyond what existing interfaces allow.
- No cross-module changes claimed as completed unless tracked in separate boundary-change beads.

### 2.3 Repo boundary discipline (how to read this plan)

This bead is documentation/planning oriented.

When this plan mentions “future work”, it is guidance for **new beads**, not an assertion that cross-module code changes are already approved or implemented.

---

## 3) First-wave runtime components to build next (minimal set)

This section lists the minimum runtime components that should be implemented next to make the architecture “real” while staying platform-neutral.

### 3.1 EncounterContext runtime skeleton (durable orchestration)

**Purpose**
- Provide the durable authority location required by ADR-0004 (“encounter-first authority”).
- Own the local orchestration state across multiple encounter instances/attempts for a peer/contact.

**Minimum responsibilities**
- Track durable IDs:
  - `encounterContextID`
  - active `encounterInstanceID`
  - active `encounterAttemptID`
- Track “pending” vs “idle” state (see encounter lifecycle doc for canonical states).
- Coordinate:
  - when to evaluate candidates (selection)
  - when to decide transitions after interruption or terminal outcomes
- Emit encounter-layer telemetry events for:
  - `selection_evaluated`
  - `transition_decided` / `transition_refused`
  - `interruption_observed`
  - `resume_evaluated` (when applicable)

**First-wave constraint**
- The skeleton may initially be conservative:
  - treat some interruptions as “resume-pending but no transfer-level resume token”
  - prefer “failover/handoff” semantics that restart the encounter attempt cleanly, while still emitting telemetry that is fixture-checkable.

### 3.2 CLA registry + snapshotting (capability snapshots + events)

**Purpose**
- Enforce ADR-0004: CLAs do not decide; they only report opportunities, capabilities, and session events.
- Provide a stable integration point for downstreams to plug in transport adapters.

**Minimum responsibilities**
- Maintain a set of registered `ConvergenceLayerAdapter` instances.
- At evaluation time:
  - obtain `BearerCapabilitySnapshot` from each CLA (deterministic order; stable sorting by `bearerID` recommended)
  - evaluate `timeScope` freshness/validity deterministically (capability model v1)
- Subscribe to each CLA’s `sessionEvents()` stream and translate those events into:
  - updates to contact/opportunity state
  - interruption markers feeding the transition decision loop

**First-wave constraint**
- A “snapshot” is sufficient; we do not require continuous capability streaming beyond event notifications.
- Capability observation timestamps should be treated as data, not as scheduling input, except for deterministic `timeScope` evaluation.

### 3.3 Selection/transition decision loop (policy-driven, deterministic)

**Purpose**
- Provide the concrete control flow that ties together:
  - capability model preflight (`timeScope` refusal mapping)
  - ADR-0004 refusal ordering (after timeScope)
  - encounter lifecycle transitions (instance/attempt scoping)
  - telemetry contract sequencing

**Minimum loop shape**
1. Collect candidate capability snapshots (CLA registry).
2. Run `EncounterOrchestrationPolicy.evaluateSelection(...)`.
3. Emit encounter telemetry: `selection_evaluated` (with ordered candidateSequence).
4. If selected:
   - open an encounter instance/attempt on that bearer (platform-specific to actually connect; in core tests this can be simulated)
   - sequence telemetry per attempt with monotonically increasing `eventSequence`
5. On interruption event (`contact_lost` / `session_idle_timeout`):
   - emit `interruption_observed`
   - mark `resumeMarkerID` (local-only) and return to candidate evaluation
6. Run `EncounterOrchestrationPolicy.decideTransition(...)`.
7. Emit `transition_decided` or `transition_refused` accordingly.

**Refusal determinism must match contracts**
- `time_scope_*` short-circuits and must not be overridden.
- ADR-0004 refusal order applies after timeScope preflight:
  `peer_incompatible`, `capability_mismatch`, `resume_not_supported`, `resume_token_invalid`, `resume_state_missing`,
  `security_posture_insufficient`, `downgrade_resistance_triggered`.

### 3.4 Telemetry sink sequencing (recording contract)

**Purpose**
- Ensure telemetry is not an afterthought: it is a first-wave gate.
- Support local-only telemetry sinks without prescribing export formats.

**Minimum responsibilities**
- Provide a `TelemetrySink` implementation hook that can:
  - record `TelemetryEvent` with correct layer attribution
  - preserve `eventSequence` monotonicity per `encounterAttemptID`
- Enforce “contract coherence” at emission time:
  - refused candidate/transition must carry `refusalReason`
  - `timeScopeEval` must be present iff refusal is `time_scope_*`
  - accepted selection/transition must not carry refusal/timeScopeEval

In AethosCore, these coherence rules already exist in the orchestration contract surface (see `OrchestrationContractError` patterns). First-wave wiring must ensure runtime code paths actually satisfy them.

---

## 4) Fixture-driven gates (MixedBearerFixtureRunnerTests as conformance)

### 4.1 What the MixedBearer fixture suite is

The MixedBearer fixture suite is the **conformance gate** for:
- telemetry event envelope shape (required keys)
- three-lane attribution model (`encounter`, `forwarding`, `admin_record`)
- deterministic timeScope invariants (`observedAt <= staleAfter`, `staleAfter <= validUntil` when present)
- refusal reason coherence (`time_scope_*` requires `timeScopeEval`, etc.)
- terminal outcome vs stopClass coherence (terminal mapping rules are enforced by tests)

This is not “nice to have”; it is the downstream integration safety net.

### 4.2 How to use it (downstream + core workflow)

**Core maintainers**
- Treat `MixedBearerFixtureRunnerTests` as a must-pass gate on any change that touches:
  - refusal reasons
  - timeScope evaluation
  - telemetry shape/keys
  - selection/transition event sequencing

**Downstream implementers**
- Use the fixture suite as the behavioral reference when building CLAs and orchestration wiring:
  - your CLA must provide capability snapshots consistent with the capability model
  - your orchestration must emit telemetry events consistent with the contract

### 4.3 Practical gate checklist (what to run / what “green” means)

**Gate A: manifest + schema version**
- The manifest `schemaVersion` must remain `mbe-mixed-bearer.v1`.
- The lanes must be exactly: `encounter`, `forwarding`, `admin_record`.

**Gate B: fixture validity and determinism**
- Every fixture must:
  - include telemetry lane keys and arrays
  - have schemaVersion matching the manifest
  - satisfy timeScope invariants
  - satisfy expected outcome/refusal coherence
  - satisfy terminal outcome/stopClass coherence
  - satisfy eventSequence monotonicity per attempt

**Gate C: integration meaning**
- Passing means:
  - the implementation respects the telemetry contract and refusal ordering invariants
  - the orchestration contract surface is stable enough to integrate with downstream CLAs

It does **not** mean:
- you have full transfer/resume continuity across bearers
- you have production transports wired up
- you have a final API surface (only “first-wave stable”)

---

## 5) Downstream cutover gates (when a platform can safely adopt MBE)

This section defines “cutover gates”: a downstream should not enable multi-bearer orchestration until these are met.

### Gate 1 — Contract parity (compile-time + API presence)
Downstream can:
- implement one or more CLAs that conform to the core adapter interface:
  - provide `currentCapabilitySnapshot(nowUnixMs:)`
  - provide `sessionEvents()` stream
- surface stable `bearerID` identifiers

### Gate 2 — Deterministic refusal behavior (capability + ADR ordering)
Downstream integration must demonstrate:
- `timeScope` is evaluated first and deterministically
- ADR-0004 refusal order is preserved after timeScope preflight
- refusal tokens match the canonical list (or `x_` extension rules are followed)

### Gate 3 — Telemetry sequencing correctness
Downstream must demonstrate:
- events are emitted with correct lane attribution
- `eventSequence` increases monotonically per `encounterAttemptID`
- refused decisions include `refusalReason` and `timeScopeEval` when required

### Gate 4 — Encounter lifecycle integrity
Downstream must demonstrate:
- one encounter instance is bound to one bearer opportunity
- switching bearers ends the old instance and creates a new instance
- interruptions are treated as markers (`contact_lost` / `session_idle_timeout`), not refusal reasons

### Gate 5 — Fixture suite conformance
Downstream is considered “cutover-ready” when:
- MixedBearer fixture runner tests pass unchanged (or with approved fixture extensions)
- any new refusal reasons are namespaced with `x_...` and declared per the telemetry contract’s extension rules

---

## 6) Risk register: transfer/resume semantics need interface expansion

### 6.1 The core risk

**True transfer/resume semantics** (especially cross-bearer resume with strong progress continuity) generally requires richer interfaces than “capability snapshot + session events”.

Examples of missing pieces that may be required in later waves:
- explicit resume token creation/validation surface
- durable per-transfer progress markers that survive interruptions and can be reconciled across CLAs
- stronger binding between encounter attempt, transport session, and transfer engine state (without violating bearer-agnostic protocol semantics)

First-wave should acknowledge this and remain conservative:
- prefer “restart cleanly with deterministic planning” while still emitting correct telemetry and refusal reasons
- represent “resume intent” and “resume evaluated” even if actual byte-level continuation is not yet supported

### 6.2 What we already have (from prior beads .10–.13)

As of the current codebase and tests:
- There are **reference CLAs** that exercise lane support and session event streams:
  - discovery-only, control-capable, transfer-capable, resumable variants
- There is a deterministic **timeScope evaluation** model (`TimeScopeEvaluator`) and canonical refusal reason tokens (`RefusalReason`).
- There is a **telemetry event envelope** model with a 3-lane attribution enum (`TelemetryLayer`) and a sink interface (`TelemetrySink`).
- There is a **fixture runner gate** (`MixedBearerFixtureRunnerTests`) and shared fixture decoding support.

These pieces are the “contract scaffolding” that first-wave builds on.

### 6.3 What remains (beyond first-wave)

- Expand the orchestration/runtime interfaces to support real resume:
  - resume marker persistence semantics
  - resume token handling (`resume_token_invalid`, `resume_state_missing`) in a way that is not “simulated”
- Define and gate the transfer engine’s interaction points with EncounterContext:
  - how pending work is represented
  - what constitutes “resumable progress”
- Add fixtures that encode real resume state transitions across multiple attempts/instances

---

## 7) Milestones (crisp, actionable) and validation per milestone

These milestones are structured so each can be validated without platform lock-in.

### Milestone M1 — EncounterContext skeleton + deterministic decision loop
**Deliver**
- AethosCore runtime skeleton that:
  - evaluates candidates via policy
  - emits `selection_evaluated`
  - reacts to interruption markers
  - emits transition decisions and refusals

**Validate**
- MixedBearer fixture runner passes.
- Additional unit tests (as needed) cover:
  - eventSequence monotonicity
  - refusal/timeScopeEval coherence
  - “one instance per bearer” invariants at the state machine level

### Milestone M2 — CLA registry + snapshot discipline
**Deliver**
- AethosCore can register multiple CLAs and produce deterministic candidate ordering/snapshots.

**Validate**
- MixedBearer fixtures include multi-candidate sequences and verify deterministic ordering and refusal mapping.

### Milestone M3 — Telemetry sink wiring and sequencing guarantees
**Deliver**
- AethosCore exposes a clean sink integration point and ensures sequencing is correct.

**Validate**
- Fixtures include multi-event attempt streams and assert monotonic sequences per attempt.
- Downstreams can attach a sink and ingest local events.

### Milestone M4 — Downstream cutover proof (reference adapter integration)
**Deliver**
- A minimal “reference integration harness” (still platform-neutral) that:
  - wires reference CLAs
  - simulates session events
  - exercises transitions and interruption handling

**Validate**
- Fixture suite passes and includes at least one interruption → transition cycle.

---

## 8) Suggested bead breakdown beyond .14 (if needed)

This bead produces the plan. Implementation work should be tracked as separate beads. Suggested next beads:

1. **aethos-3ka.15 — EncounterContext runtime skeleton**
   - Implement the durable state machine and decision loop boundaries (core-only).
   - Ensure telemetry emission points exist even if actual transport work is stubbed.

2. **aethos-3ka.16 — CLA registry + deterministic snapshot ordering**
   - Introduce a registry/manager that:
     - owns CLA set
     - produces snapshots deterministically
     - handles event stream subscription fan-in

3. **aethos-3ka.17 — Telemetry sequencing enforcement**
   - Guarantee monotonic `eventSequence` per attempt and add negative tests for regressions.

4. **aethos-3ka.18 — Fixture suite expansion: transition and interruption scenarios**
   - Add fixtures that cover:
     - interruption markers (`contact_lost`, `session_idle_timeout`)
     - transition intents (`failover`, `handoff`, `resume`)
     - refusal ordering scenarios (timeScope short-circuit, then ADR-0004 ordering)

5. **aethos-3ka.19 — Resume semantics interface expansion (boundary-aware)**
   - Only after first-wave gates are stable:
     - add explicit resume-token / resume-state interfaces
     - add fixtures that enforce `resume_token_invalid` / `resume_state_missing` semantics
   - This likely touches multiple modules and should be tagged `boundary-change` if needed.

---

## 9) Quick reference: “first-wave done” checklist

First-wave is considered complete when:

- [ ] ADR-0004 invariants are preserved by the runtime shape (encounter-first authority; scheduler authority; routing is advisory only).
- [ ] Capability model v1 timeScope evaluation is deterministic and short-circuits refusal.
- [ ] ADR-0004 refusal ordering is preserved after timeScope preflight.
- [ ] Telemetry contract is implemented with 3-lane attribution and monotonic sequencing per attempt.
- [ ] MixedBearerFixtureRunnerTests passes as the conformance gate.
- [ ] Downstream can implement a CLA without pulling platform-specific code into AethosCore.

---

## Appendix A — Key types already present in AethosCore (orientation only)

This appendix is non-normative and exists to make the plan actionable when navigating the repository.

- CLA interface:
  - `ConvergenceLayerAdapter`
  - `BearerCapabilitySnapshot`
  - `BearerSessionEvent` and `BearerSessionEventKind`
- Orchestration policy interface:
  - `EncounterOrchestrationPolicy`
  - `EncounterSelectionOutcome`, `EncounterTransitionDecision`
- Refusal/timeScope primitives:
  - `RefusalReason`
  - `TimeScope`, `TimeScopeEvaluator`, `TimeScopeEvaluation`
- Telemetry primitives:
  - `TelemetryEvent`, `TelemetryLayer`, `TelemetrySink`
- Fixture suite gate:
  - `MixedBearerFixtureRunnerTests`
  - `MixedBearerFixtureTestSupport`

These should remain platform-neutral and aligned to the protocol/ADR docs listed in §1.
