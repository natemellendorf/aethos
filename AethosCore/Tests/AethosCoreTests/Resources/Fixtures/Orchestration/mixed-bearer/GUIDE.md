# Mixed-Bearer Fixture Suite Guide (v1)

This suite defines deterministic fixture-shape conformance for mixed-bearer orchestration diagnostics.

Normative references:

- `docs/protocol/multi-bearer-telemetry.md`
- `docs/protocol/bearer-capability-model-v1.md`
- `AethosCore/Sources/AethosCore/Orchestration/Telemetry.swift`
- `AethosCore/Sources/AethosCore/Orchestration/RefusalReason.swift`
- `AethosCore/Sources/AethosCore/Orchestration/TimeScope.swift`

## 1) Discovery and loading (normative)

1. Runners MUST load `manifest.json` first.
2. Runners MUST validate every listed fixture against `schema.json`.
3. Runners MUST treat `schemaVersion: mbe-mixed-bearer.v1` as authoritative for this suite.

## 2) Required fixture shape (normative)

Each fixture MUST include:

- `schemaVersion`
- `fixtureID`
- `nowUnixMs`
- `timeScope`
- `encounter`
- `forwarding`
- `admin_record`
- `expected`

All three telemetry layer keys MUST be present even when arrays are empty:

- `encounter`
- `forwarding`
- `admin_record`

## 3) Telemetry envelope requirements (normative)

Every telemetry event object MUST include:

- `contractVersion` (MUST be `1`)
- `eventID`
- `layer`
- `eventType`
- `eventSequence`
- `occurredAtUnixMs`
- `encounterContextID`
- `encounterInstanceID`
- `encounterAttemptID`
- `payload`

Layer arrays are typed:

- `encounter[*].layer` MUST be `encounter`
- `forwarding[*].layer` MUST be `forwarding`
- `admin_record[*].layer` MUST be `admin_record`

## 4) Outcome and refusal-reason rules (normative)

1. If `expected.outcome` is `reject`, `stop`, or `defer`, `expected.refusalReason` MUST be present.
2. If `expected.outcome` is `accept`, `expected.refusalReason` MUST be absent.
3. `refusalReason` MUST be one of:
   - canonical codes from the telemetry contract, or
   - an extension code with `x_` prefix (`x_[a-z0-9_]+`).

Extension declaration requirements:

1. If a fixture uses an `x_` refusal reason, declaration MUST exist either:
   - in fixture `declaredExtensionRefusalReasons`, or
   - in manifest `extensions.declaredExtensionRefusalReasons`, with fixture flag `extensionRefusalReasonsDeclaredInManifest=true`.
2. Absence of both declaration mechanisms MUST fail schema validation.
3. Runner MUST also fail if the exact `x_` code used is not listed in the selected declaration source.

## 5) `timeScope` rules (normative)

`timeScope` fields:

- required: `observedAtUnixMs`, `staleAfterUnixMs`
- optional: `validUntilUnixMs`

All `*UnixMs` values MUST be UTC epoch milliseconds in UInt64 range.

Schema-level enforcement covers required fields and numeric domain.
Runner-level enforcement MUST validate invariants:

1. `observedAtUnixMs <= staleAfterUnixMs`
2. if `validUntilUnixMs` is present: `staleAfterUnixMs <= validUntilUnixMs`

## 6) Non-normative notes

The fixtures in this suite are primarily shape and governance vectors. Scenario-content fixtures can build on this suite in later beads.
