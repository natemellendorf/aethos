# ADR-0004: Multi-bearer encounter architecture

- Status: Proposed
- Date: 2026-04-02

## Context

Aethos already defines transport-neutral encounter semantics and deterministic reconciliation behavior. What is missing is one authoritative architecture decision that explains how multiple bearer opportunities are orchestrated without changing wire correctness.

Without this ADR, implementations can drift into bearer-specific behavior, hide transition decisions, and apply inconsistent downgrade handling across discovery, control, data transfer, and resume.

## Decision

Aethos adopts an **encounter-first, multi-bearer architecture** with strict layering invariants and an explicit downgrade resistance policy.

The encounter is the policy authority. Bearers provide opportunities. Scheduler policy decides ordering and budgets. Protocol frames remain bearer-agnostic.

## Definitions

- **Encounter**: durable orchestration context where scheduler/routing policy decides what moves first.
- **Contact**: observable peer reachability window exposing zero or more bearer opportunities.
- **Bearer**: concrete transport opportunity provider (discovery, control, data, or mixed).
- **CLA (Convergence-Layer Adapter)**: boundary that exposes bearer capability sets and session lifecycle events to encounter orchestration.
- **Session**: bounded interaction instance on one bearer within an encounter.

## Authoritative layering

```text
Policy + Scheduling Authority
  Encounter Manager (encounter-first)
    ├─ Contact view (peer reachability window)
    ├─ Capability-set evaluation and explainability
    ├─ Ordering/budget/preemption decisions
    └─ Resume and transition intent

Bearer opportunity boundary
  CLA(s)
    ├─ Capability advertisement
    ├─ Session events (open/progress/close/failure)
    └─ Transport-specific adaptation

Protocol correctness boundary
  Gossip v1 frame semantics + object invariants
    ├─ Bearer-agnostic validation and reconciliation
    └─ Deterministic convergence semantics
```

## Layering invariants

1. **Encounter-first authority**: selection, transition, and preemption decisions MUST be made at encounter scope, not inside bearer adapters.
2. **Scheduler authority**: ordering and budgeting MUST be controlled by scheduler policy bound to encounter context.
3. **Bearer-agnostic protocol semantics**: frame validity, object identity, and acceptance/rejection semantics MUST NOT vary by bearer.
4. **Capability-set explainability**: every selection or transition decision MUST be explainable using observed capability sets and active policy constraints.
5. **Explicit lifecycle transitions**: upgrade, downgrade, failover, and resume decisions MUST be explicit and observable in telemetry.
6. **Telemetry layering separation**: encounter orchestration telemetry, forwarding/reconciliation telemetry, and admin-record hooks MUST remain separately attributable.

## Decision checklist

Any architecture or implementation change in multi-bearer encounter flow MUST satisfy all checks:

- Encounter-first policy authority remains intact.
- Scheduler controls ordering and budgeting.
- Protocol frames remain bearer-agnostic.
- Selection and transition decisions are capability-set explainable.
- Upgrade/downgrade/resume decisions are explicit and observable.
- Telemetry layering remains separated (encounter / forwarding / admin-record hooks).

## Downgrade resistance policy v1

### What counts as a downgrade

Any material decrease in assurance is a downgrade, including:

- security posture drop,
- authentication assurance drop (`authnLevel`),
- integrity protection loss or weakening,
- confidentiality protection loss or weakening,
- session assurance reduction (for example weaker continuity or identity binding).

### Function-specific allow/deny policy

| Function | Policy v1 |
| --- | --- |
| Discovery | Limited downgrade MAY be allowed only for bootstrap visibility when explicitly marked non-authoritative and non-data-bearing. |
| Control | Downgrade is generally forbidden when authn/integrity/confidentiality would fall below policy minima. |
| Data | Downgrade is forbidden when protection or assurance would fall below transfer policy minima. |
| Resume | Downgrade is forbidden unless an explicit policy exception exists. Resume on a different bearer is a downgrade when assurance drops. |

### Resume on different bearer

Resuming on a different bearer is allowed only if assurance is equal or stronger than the previous session under active policy.

If assurance is weaker, the transition MUST be treated as a downgrade and refused unless an explicit policy exception authorizes it.

### Required refusal-reason mappings (minimum set)

The following refusal reasons are mandatory canonical tokens for policy denial and telemetry/spec/fixture reuse:

- `downgrade_resistance_triggered`
- `security_posture_insufficient`
- `capability_mismatch`
- `peer_incompatible`
- `resume_not_supported`
- `resume_token_invalid`
- `resume_state_missing`

## Consequences

### Positive

- Multi-bearer orchestration has one policy authority and one vocabulary.
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
