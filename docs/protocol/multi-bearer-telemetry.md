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
  "eventID": "...",
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
2. `eventID` MUST be present and MUST uniquely identify the event within local telemetry retention scope.
3. `eventSequence` MUST be monotonically increasing per `encounterAttemptID`.
4. `occurredAtUnixMs` MUST be UTC Unix epoch milliseconds.
5. Events MAY include local diagnostics fields such as `bearerID`, `bearerClass`, and `transitionIntent`.

## 5. Encounter-layer events (selection, transitions, interruption, resume)

### 5.1 `selection_evaluated`

Payload MUST include:

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

Payload MUST include:

- `transitionIntent`: one of `upgrade|downgrade|failover|handoff|resume`.
- `fromEncounterInstanceID`
- `toEncounterInstanceID` (nullable until opened)
- `selectedCandidateID` (required when decision succeeds)

### 5.3 `transition_refused`

Payload MUST include:

- `transitionIntent`
- `refusalReason`
- `timeScopeEval` (required iff `refusalReason` is `time_scope_*`)

### 5.4 `interruption_observed`

Payload MUST include:

- `interruptionReason`: one of `contact_lost|session_idle_timeout`
- `resumeMarkerID`

`interruption_observed` MUST NOT use `refusalReason`.

### 5.5 `resume_evaluated`

Payload MUST include:

- `resumeMarkerID`
- `resumeRequested` (`Bool`)
- `accepted` (`Bool`)
- `refusalReason` (required when `accepted=false`)

### 5.6 Interruption marker exclusivity (normative)

`contact_lost` and `session_idle_timeout` are interruption markers only.

1. `contact_lost` and `session_idle_timeout` MUST be emitted only as `interruptionReason` values.
2. `contact_lost` and `session_idle_timeout` MUST NOT appear as `refusalReason`.

## 6. Terminal outcomes are distinct from refusal reasons

`terminalOutcome` MUST be one of `clean-end|failed-end|policy-stop`.

Separation rules:

1. `policy_stop` is a `stopClass` token and `policy-stop` is a terminal outcome token; neither is a `refusalReason` token.
2. `refusalReason` MUST encode a concrete cause, never `policy_stop` or `policy-stop`.
3. Encounter terminal events SHOULD carry both `terminalOutcome` and causal diagnostics (`stopReason`/`stopClass` and/or `refusalReason`) when available.

## 7. Canonical `refusalReason` taxonomy (v1)

The canonical token list below defines allowed vocabulary only; it is not evaluation order. Deterministic evaluation order is defined in the mapping rules in this section and by the referenced capability/ADR contracts.

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

Deterministic evaluation attribution:

1. `time_scope_*` tokens MUST be produced by capability-set preflight only, using `docs/protocol/bearer-capability-model-v1.md` ordering.
2. ADR-0004 refusal ordering (`peer_incompatible`, `capability_mismatch`, `resume_not_supported`, `resume_token_invalid`, `resume_state_missing`, `security_posture_insufficient`, `downgrade_resistance_triggered`) MUST be preserved after `timeScope` preflight.
3. `resource_limit_exceeded` and `budget_exhausted` are forwarding/planning refusal causes and MUST NOT overwrite prior `time_scope_*` or ADR-ordered refusal causes for the same decision.
4. `contact_lost` and `session_idle_timeout` MUST NOT be used as refusal causes.
5. When interruption recovery fails after re-evaluation, refusal resolution MUST use non-interruption refusal tokens (for example `session_unavailable` or applicable `resume_*` reason).

## 8. Deterministic `timeScopeEval` structure

If `refusalReason` is one of `time_scope_stale|time_scope_expired|time_scope_invalid`, `timeScopeEval` MUST be present and MUST include these required keys:

- `observedAtUnixMs`
- `staleAfterUnixMs`
- `nowUnixMs`
- `invariants.observedAtLteStaleAfter`
- `result`

Optional keys:

- `validUntilUnixMs` (present only when hard cutoff exists)
- `invariants.staleAfterLteValidUntil` (present only when `validUntilUnixMs` is present)

Example (with `validUntilUnixMs` present):

```json
{
  "observedAtUnixMs": 0,
  "staleAfterUnixMs": 0,
  "nowUnixMs": 0,
  "validUntilUnixMs": 0,
  "invariants": {
    "observedAtLteStaleAfter": true,
    "staleAfterLteValidUntil": true
  },
  "result": "time_scope_invalid|time_scope_expired|time_scope_stale"
}
```

`timeScopeEval` key semantics are:

1. `observedAtUnixMs`, `staleAfterUnixMs`, `nowUnixMs`, and optional `validUntilUnixMs` are UTC Unix epoch milliseconds (`UInt64`).
2. `validUntilUnixMs` is optional and MUST be omitted when no hard cutoff exists.
3. If `validUntilUnixMs` is omitted, `invariants.staleAfterLteValidUntil` MUST be omitted.
4. If `validUntilUnixMs` is present, `invariants.staleAfterLteValidUntil` MUST be present.

Telemetry naming uses explicit `*UnixMs` keys and is derived from capability-model `timeScope` fields (`observedAt`, `staleAfter`, `validUntil`) in `docs/protocol/bearer-capability-model-v1.md`.

Deterministic mapping MUST be:

1. Invariant violation -> `time_scope_invalid`
2. Else, if `validUntilUnixMs` is present and `nowUnixMs >= validUntilUnixMs` -> `time_scope_expired`
3. Else (`nowUnixMs >= staleAfterUnixMs`) -> `time_scope_stale`

When `validUntilUnixMs` is absent, step 2 MUST be skipped.

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

Disambiguation (mandatory): scheduler `stopReason=encounter-time-exhausted` is a budgeting/classification stop and maps to clean-end policy handling; it MUST NOT be conflated with interruption marker `session_idle_timeout`.

## 11. Admin-record hooks (optional, local-only)

Admin-record events are optional and local-only hooks to capture audit/management record emission state.

When emitted, they MUST include:

- `hookName`
- `hookOutcome`: `queued|emitted|dropped|failed`
- `sourceEventRef.eventID` (required): the `eventID` of the encounter-layer or forwarding-layer source event

`sourceEventRef` MUST be an object that contains `eventID` as a string key.

Admin-record hook failures MUST NOT retroactively change encounter or forwarding outcomes.

## 12. Shadow migration telemetry compatibility

When shadow comparison is enabled, mismatch classes from `docs/protocol/encounter-shadow-migration-note.md` SHOULD be emitted as forwarding-layer diagnostics and correlated to the same `encounterAttemptID`.

Shadow mismatch classes are diagnostics, not refusal reasons.
