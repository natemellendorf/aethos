# Mixed-Bearer Fixture Versioning and Change Control

This suite is normative for mixed-bearer fixture-shape conformance in schema version `mbe-mixed-bearer.v1`.

## Change categories

1. Non-semantic edits (spelling, formatting, prose clarity)
   - MUST NOT alter validation semantics.

2. Fixture-semantic edits (fixture outcomes, refusal reason values, declaration references)
   - MUST include rationale tied to protocol text.
   - MUST update affected governance notes in `GUIDE.md`.

3. Schema contract edits (required keys, envelope fields, refusal taxonomy, timeScope field rules)
   - MUST be treated as contract-impacting.
   - MUST publish a new schema version and suite version.
   - MUST provide migration guidance for runners.

## Mandatory review checklist

- Validate all fixture JSON files against `schema.json`.
- Confirm `telemetry` always includes `encounter`, `forwarding`, and `admin_record`.
- Confirm reject/stop/defer fixtures always include `refusalReason`.
- Confirm extension refusal reasons are declared in fixture or manifest per suite rules.
- Confirm all `*UnixMs` fields remain in UInt64 domain.

## Versioning rules

- Keep `schemaVersion: mbe-mixed-bearer.v1` unchanged for non-structural edits.
- If schema structure changes, publish `mbe-mixed-bearer.v2` (or later) and a matching suite update.
- Do not silently change v1 semantics.
