# Multi-bearer Telemetry and Explainability Contract (v1)

Status: normative local-only telemetry/explainability contract for bearer selection, transitions, interruption, and resume.

## 1. Normative language and scope

The key words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** are to be interpreted as in RFC 2119.

This contract is local diagnostics only:

1. Telemetry defined here MUST remain local-only and MUST NOT be exported as protocol payload.
2. This contract MUST NOT modify wire schema, frame validity, or reconciliation rules.
3. This contract MUST preserve the encounter-first authority and layering invariants from `docs/adr/ADR-0004-multi-bearer-encounter-architecture.md`.

## 2. Integration boundaries (no contract rewrites)

This document composes existing contracts without replacing them:

1. `docs/protocol/encounter.md` remains authoritative for encounter lifecycle and terminal outcomes.
2. `docs/protocol/encounter-budgeting.md` §5 remains authoritative for scheduler explainability fields (`stopReason`, `stopClass`, score breakdown).
3. `docs/protocol/bearer-capability-model-v1.md` remains authoritative for capability-set preflight and deterministic `timeScope` refusal mapping.
4. `docs/protocol/encounter-shadow-migration-note.md` remains authoritative for shadow-diff classes and migration interpretation.

## 3. Three-layer telemetry model (mandatory attribution)

Every telemetry event MUST declare exactly one layer:

- `encounter`: bearer selection, transition intent, refusal, interruption, and resume orchestration.
- `forwarding`: item ranking/selection/budget explainability from scheduler/reconciliation flow.
- `admin_record`: optional administrative-record hook status for local policy/audit integration.

Layer separation rules:

1. Encounter-layer events MUST NOT claim forwarding ranking authority.
2. Forwarding-layer events MUST NOT claim bearer-selection or transition authority.
3. Admin-record events MUST NOT alter encounter/forwarding decisions; they are hooks only.

## 4. Common event envelope (required keys)

Each event MUST include:

```json
{
  "contractVersion": 1,
  "layer": "encounter|forwarding|admin_record",
  "eventType": "...",
  "eventSequence": 0,
  "occurredAtUnixMs": 0,
  "encounterContextID": "...",
  "encounterInstanceID": "...",
  "encounterAttemptID": "..."
}
```

Rules:

1. `contractVersion` MUST be `1`.
2. `eventSequence` MUST be monotonically increasing per `encounterAttemptID`.
3. `occurredAtUnixMs` MUST be UTC Unix epoch milliseconds.
4. Events MAY include local diagnostics fields such as `bearerID`, `bearerClass`, and `transitionIntent`.

## 5. Encounter-layer events (selection, transitions, interruption, resume)

### 5.1 `selection_evaluated`

Required payload keys:

- `candidateSequence`: ordered list of evaluated bearer candidates.
- `selectedCandidateID` (nullable).
- `requiredLanes`: subset of `discovery|control|data|resume`.

Each `candidateSequence[]` entry MUST include:

- `candidateID`
- `candidateOrder` (0-based deterministic order)
- `accepted` (`Bool`)
- `refusalReason` (required when `accepted=false`)
- `timeScopeEval` (required when `refusalReason` is `time_scope_*`)

### 5.2 `transition_decided`

Required payload keys:

- `transitionIntent`: one of `upgrade|downgrade|failover|handoff|resume`.
- `fromEncounterInstanceID`
- `toEncounterInstanceID` (nullable until opened)
- `selectedCandidateID` (required when decision succeeds)

### 5.3 `transition_refused`

Required payload keys:

- `transitionIntent`
- `refusalReason`
- `timeScopeEval` (required iff `refusalReason` is `time_scope_*`)

### 5.4 `interruption_observed`

Required payload keys:

- `interruptionReason`: one of `contact_lost|encounter_timeout|session_idle_timeout`
- `resumeMarkerID`

`interruption_observed` MUST NOT use `refusalReason`.

### 5.5 `resume_evaluated`

Required payload keys:

- `resumeMarkerID`
- `resumeRequested` (`Bool`)
- `accepted` (`Bool`)
- `refusalReason` (required when `accepted=false`)

## 6. Terminal outcomes are distinct from refusal reasons

`terminalOutcome` MUST be one of `clean-end|failed-end|policy-stop`.

Separation rules:

1. `policy_stop` is a `stopClass` token and `policy-stop` is a terminal outcome token; neither is a `refusalReason` token.
2. `refusalReason` MUST encode a concrete cause, never `policy_stop` or `policy-stop`.
3. Encounter terminal events SHOULD carry both `terminalOutcome` and causal diagnostics (`stopReason`/`stopClass` and/or `refusalReason`) when available.

## 7. Canonical `refusalReason` taxonomy (v1)

Canonical minimum tokens:

1. `security_posture_insufficient`
2. `downgrade_resistance_triggered`
3. `resource_limit_exceeded`
4. `budget_exhausted`
5. `time_scope_stale`
6. `time_scope_expired`
7. `time_scope_invalid`
8. `capability_mismatch`
9. `peer_incompatible`
10. `session_unavailable`
11. `resume_not_supported`
12. `resume_token_invalid`
13. `resume_state_missing`
14. `encounter_timeout`
15. `contact_lost`

Deterministic evaluation attribution:

1. `time_scope_*` tokens MUST be produced by capability-set preflight only, using `docs/protocol/bearer-capability-model-v1.md` ordering.
2. ADR-0004 refusal ordering (`peer_incompatible`, `capability_mismatch`, `resume_not_supported`, `resume_token_invalid`, `resume_state_missing`, `security_posture_insufficient`, `downgrade_resistance_triggered`) MUST be preserved after `timeScope` preflight.
3. `resource_limit_exceeded` and `budget_exhausted` are forwarding/planning refusal causes and MUST NOT overwrite prior `time_scope_*` or ADR-ordered refusal causes for the same decision.
4. `contact_lost` and `encounter_timeout` MAY be used as refusal causes only for transition/resume refusal resolution after interruption context is re-evaluated; they MUST NOT replace the `interruptionReason` field on `interruption_observed`.

## 8. Deterministic `timeScopeEval` structure

If `refusalReason` is one of `time_scope_stale|time_scope_expired|time_scope_invalid`, `timeScopeEval` MUST be present and MUST include:

```json
{
  "observedAt": 0,
  "staleAfter": 0,
  "validUntil": 0,
  "nowUnixMs": 0,
  "invariants": {
    "observedAtLteStaleAfter": true,
    "staleAfterLteValidUntil": true
  },
  "result": "time_scope_invalid|time_scope_expired|time_scope_stale"
}
```

Deterministic mapping MUST be:

1. Invariant violation -> `time_scope_invalid`
2. Else (`validUntil` present and `nowUnixMs >= validUntil`) -> `time_scope_expired`
3. Else (`nowUnixMs >= staleAfter`) -> `time_scope_stale`

This ordering MUST match `docs/protocol/bearer-capability-model-v1.md`.

## 9. Extension rule for non-canonical refusal reasons

Non-canonical refusal reasons are allowed only via explicit extension namespace:

1. Any non-canonical `refusalReason` MUST match `x_[a-z0-9_]+`.
2. Any event using `x_` refusal reason MUST include (or reference in the same log batch/fixture file) a `declaredExtensionRefusalReasons` registry containing that exact code.
3. `declaredExtensionRefusalReasons` entries MUST include `code`, `layer`, and `description`.
4. Unknown non-`x_` refusal reasons MUST be treated as schema-invalid telemetry.

Example declaration mechanism:

```json
{
  "declaredExtensionRefusalReasons": [
    {
      "code": "x_radio_scan_busy",
      "layer": "encounter",
      "description": "Local radio scanner is occupied by higher-priority operation"
    }
  ]
}
```

## 10. Forwarding-layer linkage (encounter budgeting contract)

Forwarding events MUST carry scheduler explainability fields from `docs/protocol/encounter-budgeting.md` §5, including:

- encounter class
- candidate counts by tier
- score breakdown
- `stopReason`
- `stopClass`
- interruption/resume markers

`stopReason`/`stopClass` remain scheduler diagnostics and MUST NOT be retyped as `refusalReason` unless an explicit transition/selection refusal event is emitted.

## 11. Admin-record hooks (optional, local-only)

Admin-record events are optional and local-only hooks to capture audit/management record emission state.

When emitted, they MUST include:

- `hookName`
- `hookOutcome`: `queued|emitted|dropped|failed`
- `sourceEventRef` (event id/reference to encounter or forwarding event)

Admin-record hook failures MUST NOT retroactively change encounter or forwarding outcomes.

## 12. Shadow migration telemetry compatibility

When shadow comparison is enabled, mismatch classes from `docs/protocol/encounter-shadow-migration-note.md` SHOULD be emitted as forwarding-layer diagnostics and correlated to the same `encounterAttemptID`.

Shadow mismatch classes are diagnostics, not refusal reasons.
