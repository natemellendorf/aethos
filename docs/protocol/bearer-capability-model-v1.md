# Bearer Capability Model v1

Status: normative capability-set contract for multi-bearer encounter orchestration.

## 1. Normative language and scope

The key words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** are to be interpreted as in RFC 2119.

This document defines the canonical capability-set model used by `EncounterContext` policy evaluation.

- Capability evaluation is **local-only** characterization of a bearer opportunity/session surfaced by a CLA (Transport Adapter).
- Capability evaluation is **bearer-agnostic at frame level** and MUST NOT alter Gossip V1 frame schema, validation, or reconciliation semantics.

## 2. Terminology alignment (ADR-0004)

- **Encounter**: bounded peer interaction on one bearer opportunity.
- **EncounterContext**: durable orchestration state across encounters; owns policy memory and selection/transition decisions.
- **CLA / Transport Adapter**: equivalent terms for the adaptation boundary that reports observed bearer properties.
- **Capability set**: versioned, local-only input from CLA observations into `EncounterContext` policy decisions.

## 3. Canonical capability-set envelope (v1)

Every capability set MUST use the following top-level structure:

```json
{
  "capabilitySetVersion": 1,
  "timeScope": { ... },
  "securityPosture": { ... },
  "transferSemantics": { ... },
  "resourceLimits": { ... },
  "keepaliveIdleRules": { ... }
}
```

All timestamps in this model are UTC Unix epoch milliseconds (`UInt64`).
Comparisons MUST use UTC Unix-millisecond numeric values; local timezone/locale MUST NOT affect evaluation.

## 4. Field definitions (required unless noted)

### 4.1 `timeScope`

```json
{
  "observedAt": 0,
  "staleAfter": 0,
  "validUntil": 0
}
```

- `observedAt` (`UInt64`, required): observation timestamp for this capability set.
- `staleAfter` (`UInt64`, required): freshness cutoff for using this capability set.
- `validUntil` (`UInt64`, optional): hard validity cutoff.

Invariants (deterministic, mandatory):

1. `observedAt <= staleAfter`
2. if `validUntil` is present: `staleAfter <= validUntil`

Deterministic refusal mapping (mandatory):

1. if `nowUnixMs >= staleAfter` -> `time_scope_stale`
2. if `validUntil` is present and `nowUnixMs >= validUntil` -> `time_scope_expired`
3. if any invariant is violated -> `time_scope_invalid`

If multiple conditions are true, implementations MUST use this first-match precedence order.

### 4.2 `securityPosture`

```json
{
  "securityPostureClass": 0,
  "authenticationAssuranceLevel": 0,
  "integrityProtectionLevel": 0,
  "confidentialityLevel": 0,
  "sessionBindingLevel": 0
}
```

All values are unsigned integer classes (`0...255`) where larger means stronger assurance.

`EncounterContext` downgrade-resistance checks MUST compare the full assurance vector component-wise and MUST refuse when any required component drops below policy minimum or active-session baseline (`security_posture_insufficient` or `downgrade_resistance_triggered`, per ADR-0004).

### 4.3 `transferSemantics`

```json
{
  "supportsDiscovery": true,
  "supportsControl": true,
  "supportsData": true,
  "supportsResume": true,
  "orderedDelivery": true,
  "reliabilityClass": 0
}
```

- `supportsDiscovery`, `supportsControl`, `supportsData`, `supportsResume`: function exposure booleans.
- `orderedDelivery` (`Bool`): ordering guarantee for this opportunity.
- `reliabilityClass` (`UInt8`): local reliability class (`0...255`) used for deterministic local ranking only.

If requested function semantics are unsupported, refusal MUST be deterministic (`capability_mismatch` or `resume_not_supported` as applicable).

### 4.4 `resourceLimits`

```json
{
  "maxFrameBytes": 0,
  "preferredTransferUnitBytes": 32768,
  "estimatedGoodputBytesPerSecond": 0,
  "maxConcurrentSessions": 1
}
```

- `maxFrameBytes` (`UInt32`, >= 1)
- `preferredTransferUnitBytes` (`UInt32`, >= 1)
- `estimatedGoodputBytesPerSecond` (`UInt64`, >= 0)
- `maxConcurrentSessions` (`UInt16`, >= 1)

`preferredTransferUnitBytes` SHOULD be `32768` for MVP0 compatibility.

### 4.5 `keepaliveIdleRules`

```json
{
  "requiresKeepalive": true,
  "keepaliveIntervalMs": 0,
  "idleTimeoutMs": 0,
  "hardSessionLifetimeMs": 0,
  "maxConsecutiveMissedKeepalives": 0
}
```

- `requiresKeepalive` (`Bool`)
- `keepaliveIntervalMs` (`UInt64`, optional; required when `requiresKeepalive=true`)
- `idleTimeoutMs` (`UInt64`, required, > 0)
- `hardSessionLifetimeMs` (`UInt64`, optional)
- `maxConsecutiveMissedKeepalives` (`UInt16`, optional)

Invariants:

1. if `requiresKeepalive=true`, `keepaliveIntervalMs` MUST be present
2. if `keepaliveIntervalMs` is present, `keepaliveIntervalMs < idleTimeoutMs`
3. if `hardSessionLifetimeMs` is present, `hardSessionLifetimeMs >= idleTimeoutMs`

## 5. Deterministic evaluation flow (local-only)

For each candidate capability set, `EncounterContext` MUST evaluate in this order:

1. parse/version checks (`capabilitySetVersion == 1`)
2. `timeScope` invariants and freshness/expiry mapping (`time_scope_stale`, `time_scope_expired`, `time_scope_invalid`)
3. requested-function compatibility (`capability_mismatch`, `resume_not_supported`)
4. ADR-0004 downgrade/assurance policy refusal order for remaining checks

If step 2 refuses, later checks MUST NOT override the `time_scope_*` refusal reason.

## 6. Mapping guidance: observation -> capability fields -> refusal outcomes

| CLA observation | Capability field(s) | Deterministic refusal (if unmet) |
| --- | --- | --- |
| Observation timestamp too old for current `nowUnixMs` | `timeScope.staleAfter` | `time_scope_stale` |
| Capability lease lifetime elapsed | `timeScope.validUntil` | `time_scope_expired` |
| Timestamp ordering broken | `timeScope.observedAt`, `staleAfter`, `validUntil` | `time_scope_invalid` |
| No control/data exposure for requested function | `transferSemantics.supportsControl` / `supportsData` | `capability_mismatch` |
| Resume requested but not exposed | `transferSemantics.supportsResume` | `resume_not_supported` |
| Assurance below required minima | `securityPosture.*` vector | `security_posture_insufficient` |
| Assurance weaker than active baseline | `securityPosture.*` vector | `downgrade_resistance_triggered` |

## 7. Extension mechanism (mandatory)

Extension keys and codes are explicit and namespaced:

- Any object in this model MAY include additional keys prefixed with `x_`.
- Unknown non-`x_` keys MUST be treated as schema-invalid input.
- Unknown `x_` keys MUST be ignored unless explicitly recognized by local policy.
- Extension refusal reason codes MUST use the prefix form `x_[a-z0-9_]+`.

## 8. Fixture schema reference

Capability-model fixtures MUST validate against:

- `Fixtures/Routing/encounter-capability-model/schema.json`

That schema locks in v1 field shape, timestamp type bounds, deterministic refusal token set (including `time_scope_*`), and the `x_` extension namespace rules.
