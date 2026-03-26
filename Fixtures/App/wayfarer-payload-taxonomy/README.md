# Wayfarer payload taxonomy fixtures

Conformance fixtures for app payload handling outcomes defined in:

- `docs/app/WAYFARER_PAYLOAD_CONTRACT.md`
- `docs/app/WAYFARER_COMPATIBILITY_MATRIX.md`

## Fixture format

Each fixture file is JSON with these top-level fields:

- `id`: stable fixture identifier
- `description`: human-readable scenario summary
- `body_cbor_hex`: authoritative `Envelope.body` bytes (deterministic CBOR for decode-success fixtures; may be invalid bytes for decode-failure fixtures)
- `expected_decoded_map`: expected decoded top-level map representation (present for decode-success fixtures only)
- `envelope_context`: envelope metadata relevant to app-layer checks
- `expected_outcome`: one of:
  - `accept/display`
  - `accept/store-no-display`
  - `unsupported-safe-skip`
  - `reject`

For decode-failure fixtures, `body_cbor_hex` remains authoritative input and `expected_decoded_map` is omitted.

`manifest.json` indexes all fixtures and repeats expected outcomes for machine-readable harnesses.

## Scenarios included

1. Valid `wayfarer.chat.v1`
2. Valid `wayfarer.media_manifest.v1`
3. Malformed `wayfarer.chat.v1`
4. Unknown future payload type
5. Body bytes failing app decode requirements (invalid CBOR / decoded non-map / non-text keys)
6. Reserved type placeholders:
   - `wayfarer.profile.v1`
   - `wayfarer.reaction.v1`
   - `wayfarer.message_update.v1`
   - `wayfarer.status_event.v1`
   - `wayfarer.notice.v1`

## Safety invariant

Unknown or unsupported payload types MUST NOT be interpreted as `wayfarer.chat.v1`.

## Conformance runner contract (MUST)

Runners MUST execute fixtures in this order:

1. Start from fixture `body_cbor_hex` bytes (authoritative input).
2. Attempt CBOR decode.
3. If decode succeeds, verify decoded top-level map exactly matches `expected_decoded_map`.
4. Classify by decoded `type` only.
5. Verify final handling outcome equals `expected_outcome`.

No runner may start from `expected_decoded_map` as input.

No runner may use `manifest_id` or any envelope metadata to infer payload type.

## Fixture mirroring status

These fixtures are authoritative in `Fixtures/App/wayfarer-payload-taxonomy/`.
