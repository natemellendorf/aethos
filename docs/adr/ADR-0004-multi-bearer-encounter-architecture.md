# ADR-0004: Multi-bearer encounter architecture

- Status: Proposed
- Date: 2026-04-02

## Context

Aethos already defines transport-neutral encounter semantics and deterministic reconciliation behavior (`docs/protocol/encounter.md`, ADR-0002). What is missing is one authoritative architecture decision for multi-bearer orchestration that preserves those semantics while making selection, transition, and downgrade behavior explicit.

Without this ADR, implementations can drift into bearer-specific behavior, conflate routing and scheduling authority, and apply inconsistent downgrade handling across discovery, control, data transfer, and resume.

## Decision

Aethos adopts an **encounter-first, multi-bearer architecture** with strict layering invariants and an explicit downgrade resistance policy.

Encounter orchestration is anchored in a durable `EncounterContext`. Individual encounters remain bounded peer interactions with transport-neutral Gossip V1 semantics.

Bearers provide opportunities. Routing generates candidates. Scheduler policy is the final authority for ordering and budgets. Protocol frames remain bearer-agnostic.

## Definitions

- **Encounter**: bounded, temporary peer interaction that runs Gossip V1 frame exchange on a bearer opportunity.
- **EncounterContext**: durable orchestration state for a peer/contact relationship across multiple encounters; owns policy memory and scheduling/routing decisions.
- **Contact**: observable peer reachability window exposing zero or more bearer opportunities.
- **Bearer**: concrete transport opportunity provider that may expose discovery, control, and/or data capabilities; even when multiplexed on one transport, those functions remain logically separated by policy and telemetry.
- **CLA (Convergence-Layer Adapter) / Transport Adapter**: adaptation boundary that surfaces bearer capability sets and session lifecycle events to encounter orchestration.
- **Session**: bounded interaction instance on one bearer opportunity within one encounter.

## Runtime component mapping to ADR-0002

| This ADR term | ADR-0002 term | Mapping rule |
| --- | --- | --- |
| Encounter orchestration (`EncounterContext`) | Encounter Engine + Policy Layer | `EncounterContext` is the durable policy/scheduling memory; each Encounter is executed by Encounter Engine behavior plus local Policy Layer decisions. |
| CLA | Transport Adapter | Same boundary; this ADR allows both names but treats them as equivalent. |
| Gossip V1 correctness boundary | Gossip V1 frame semantics in Encounter Engine | No change to wire semantics, validation, or reconciliation invariants. |

## Authoritative layering

```text
Policy + Scheduling Authority
  EncounterContext (Encounter Engine + Policy Layer)
    ├─ Contact view (peer reachability window)
    ├─ Capability-set evaluation and explainability
    ├─ Ordering/budget/preemption decisions
    └─ Resume and transition intent

Bearer opportunity boundary
  CLA(s) / Transport Adapter(s)
    ├─ Capability advertisement
    ├─ Session events (open/progress/close/failure)
    └─ Transport-specific adaptation

Protocol correctness boundary
  Gossip V1 frame semantics + object invariants
    ├─ Bearer-agnostic validation and reconciliation
    └─ Deterministic convergence semantics
```

## Layering invariants

1. **Encounter-first authority**: selection, transition, and preemption decisions MUST be made at encounter scope (`EncounterContext`), not inside CLAs/Transport Adapters.
2. **Scheduler final authority**: scheduler policy MUST be the final authority for ordering and budgeting decisions.
3. **Routing candidate boundary**: routing MAY propose candidates, but routing MUST NOT violate scheduler tiers (priority/budget classes in `docs/protocol/encounter-budgeting.md`), budgets, or preemption outcomes.
4. **Bearer-agnostic protocol semantics**: Gossip V1 frame validity, object identity, and acceptance/rejection semantics MUST NOT vary by bearer.
5. **Function separation**: discovery, control, and data decisions MUST remain logically separated by policy, accounting, and telemetry, even when one bearer multiplexes multiple functions.
6. **Capability-set explainability**: every selection or transition decision MUST be explainable using observed capability sets and active policy constraints.
7. **Explicit lifecycle transitions**: upgrade, downgrade, failover, and resume decisions MUST be explicit and observable in telemetry.
8. **Telemetry layering separation**: encounter orchestration telemetry, forwarding/reconciliation telemetry, and administrative-record telemetry hooks MUST remain separately attributable.

Canonical capability-set shape and deterministic `timeScope` evaluation for this ADR are defined in `docs/protocol/bearer-capability-model-v1.md`.

## Decision checklist

Any architecture or implementation change in multi-bearer encounter flow MUST satisfy all checks:

- Encounter authority remains anchored in `EncounterContext` while Encounter keeps the bounded-session meaning.
- Scheduler is the final authority for ordering and budgeting.
- Routing only proposes candidates and does not override scheduler tiers/budgets.
- Discovery/control/data remain logically separated even on multiplexed bearers.
- Gossip V1 protocol frames remain bearer-agnostic.
- Selection and transition decisions are capability-set explainable.
- Upgrade/downgrade/resume decisions are explicit and observable.
- Telemetry layering remains separated (encounter / forwarding / administrative-record hooks).

## Downgrade resistance policy v1

### What counts as a downgrade

Any material decrease in assurance is a downgrade, including:

- security posture drop,
- authentication assurance level drop,
- integrity protection loss or weakening,
- confidentiality protection loss or weakening,
- session assurance reduction (for example weaker continuity or identity binding).

Assurance comparison MUST be evaluated using a deterministic local assurance vector for each function decision point: security posture class, authentication assurance level, integrity class, confidentiality class, and session continuity binding level.

### Function-specific allow/deny policy

| Function | Policy v1 |
| --- | --- |
| Discovery | Limited downgrade MAY be allowed only for bootstrap visibility when explicitly marked non-authoritative and non-data-bearing. Discovery downgrade MUST NOT authorize control or data transfer. |
| Control | Control transition MUST be refused if authentication assurance, integrity, confidentiality, or security posture would fall below control policy minima. |
| Data | Data transfer transition MUST be refused if assurance would fall below transfer policy minima. |
| Resume | Resume transition MUST be refused when assurance would decrease, unless an explicit policy exception exists. Resume on a different bearer is a downgrade when assurance drops. |

### Resume on different bearer

Resuming on a different bearer is allowed only if assurance is equal or stronger than the previous session under active policy.

If assurance is weaker, the transition MUST be treated as a downgrade and refused unless an explicit policy exception authorizes it.

### Deterministic refusalReason mapping (required)

The following refusal reasons are mandatory canonical tokens for policy denial and telemetry/spec/fixture reuse.

Implementations MUST evaluate refusal conditions in the listed order, and `refusalReason` MUST be the first matching row.

This mapping applies after capability-set preflight; `time_scope_*` short-circuit outcomes are evaluated before these rows per `docs/protocol/bearer-capability-model-v1.md`.

| Evaluation order | Deterministic condition (first match wins) | refusalReason |
| --- | --- | --- |
| 1 | Peer cannot satisfy required protocol/identity compatibility for requested function | `peer_incompatible` |
| 2 | No candidate bearer exposes the minimum required capability set for requested function | `capability_mismatch` |
| 3 | Resume requested but peer/bearer does not advertise resume capability | `resume_not_supported` |
| 4 | Resume requested and presented resume token is invalid | `resume_token_invalid` |
| 5 | Resume requested and required prior resume state is missing/expired locally | `resume_state_missing` |
| 6 | Candidate fails absolute security posture minimum for requested function | `security_posture_insufficient` |
| 7 | Candidate would reduce assurance versus current/baseline state without explicit exception | `downgrade_resistance_triggered` |

Rows 3-5 are resume-specific and apply only to resume decisions. Rows 1, 2, 6, and 7 apply across discovery/control/data/resume as relevant.

## Consequences

### Positive

- Multi-bearer orchestration has one policy authority and one vocabulary.
- Terminology now aligns Encounter meaning with existing protocol documents.
- Upgrade/downgrade/resume behavior becomes consistent and auditable.
- Downstream specs and fixtures can reuse canonical refusal reasons.

### Risks

- Ambiguous assurance thresholds can still cause inconsistent local policy decisions.
- Discovery downgrade exceptions can leak into control/data decisions if boundaries are not enforced.

## Non-goals

- No new wire protocol behavior.
- No platform-framework lock-in.
- No production implementation details.

## Terminology

- **Assurance**: combined security/authentication/integrity/confidentiality/session-continuity confidence used for policy decisions.
- **Downgrade**: any transition that reduces assurance below previous state or policy minima.
- **Upgrade**: transition that increases assurance while preserving protocol invariants.
- **Capability set**: observed bearer/session properties used by policy to make explainable decisions.
- **Administrative-record telemetry hooks**: policy/audit emission points for management records, logically distinct from encounter and forwarding telemetry streams.
