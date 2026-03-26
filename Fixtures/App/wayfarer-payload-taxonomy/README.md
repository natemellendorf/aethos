# Wayfarer payload taxonomy fixtures

Conformance fixtures for app payload handling outcomes defined in:

- `docs/app/WAYFARER_PAYLOAD_CONTRACT.md`
- `docs/app/WAYFARER_COMPATIBILITY_MATRIX.md`

## Fixture format

Each fixture file is JSON with these top-level fields:

- `id`: stable fixture identifier
- `description`: human-readable scenario summary
- `body_source`: how `Envelope.body` bytes are represented in the fixture
  - `format=decoded_cbor_map`: fixture provides `decoded_body_map` (explicit decoded top-level CBOR map with text keys)
  - `format=raw_bytes_hex`: fixture provides raw bytes for malformed body scenarios where app decode requirements fail (for example invalid CBOR, decoded non-map, or non-text keys)
- `decoded_body_map`: decoded app-layer map used for classification/validation (present when `format=decoded_cbor_map`)
- `envelope_context`: envelope metadata relevant to app-layer checks (for example canonical author identity)
- `expected_outcome`: one of:
  - `accept/display`
  - `accept/store-no-display`
  - `unsupported-safe-skip`
  - `reject`

Classification MUST read `decoded_body_map.type` (or reject if no decodable map/type). Fixtures intentionally do not provide any `manifest_family` shortcut.

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

## Fixture mirroring status

These fixtures are currently authoritative in `Fixtures/App/wayfarer-payload-taxonomy/` only. They are not mirrored into `AethosCore/Tests/.../Resources/Fixtures/App/...` yet because no app-layer fixture harness is wired there today, and this bead remains doc/fixture focused.
