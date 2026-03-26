# Wayfarer payload taxonomy fixtures

Conformance fixtures for app payload handling outcomes defined in:

- `docs/app/WAYFARER_PAYLOAD_CONTRACT.md`
- `docs/app/WAYFARER_COMPATIBILITY_MATRIX.md`

## Fixture format

Each fixture file is JSON with these top-level fields:

- `id`: stable fixture identifier
- `description`: human-readable scenario summary
- `manifest_family`: declared payload family key used for dispatch
- `envelope`: envelope metadata context relevant to payload-layer handling
- `payload`: decoded logical payload shape for the declared family
- `expected_outcome`: one of:
  - `accept/display`
  - `accept/store-no-display`
  - `unsupported-safe-skip`
  - `reject`

`manifest.json` indexes all fixtures and repeats expected outcomes for machine-readable test harness use.

## Scenarios included

1. Valid `chat.v1`
2. Valid `media_manifest.v1`
3. Malformed `chat.v1`
4. Unknown future payload family
5. Reserved family placeholders:
   - `reserved.system.*`
   - `reserved.control.*`

## Safety invariant

Unknown or unsupported families MUST NOT be interpreted as `chat.v1`.
