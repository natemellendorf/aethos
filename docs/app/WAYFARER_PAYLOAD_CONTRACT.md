# WAYFARER_PAYLOAD_CONTRACT

Status: Canonical app payload contract for Wayfarer app-layer payload semantics (MVP0)

## 1. Normative language

The key words **MUST**, **MUST NOT**, **REQUIRED**, **SHOULD**, and **MAY** are to be interpreted as described in RFC 2119.

## 2. Scope and authority boundaries

1. Frame parsing, envelope validation, hash/signature verification, and forwarding are protocol-layer responsibilities.
2. `Envelope.body: bstr` remains opaque at protocol layer.
3. This contract defines app-layer interpretation of `Envelope.body` bytes for Wayfarer payload taxonomy.
4. App-layer outcomes MUST NOT mutate protocol validity decisions.

Boundary rule:

- Protocol asks: "Is this envelope authentic and transport-valid?"
- App taxonomy asks: "What payload `type` does this body represent, and how must it be handled?"

These decisions MUST remain separate.

## 3. Encoding contract for `Envelope.body` (strict fail-closed)

1. Wayfarer app payload bodies MUST be deterministic CBOR (RFC 8949 deterministic encoding).
2. JSON, plain text, and any non-CBOR encoding are invalid.
3. There is no legacy or alternate encoding path.
4. Bodies that fail CBOR decoding MUST be rejected.
5. Decoded top-level value MUST be a map.
6. Map keys MUST be CBOR text strings.
7. Decoded map MUST include top-level `type` as a CBOR text string.

If any requirement above fails, outcome is `reject`.

## 4. Canonical classification algorithm (only allowed path)

Implementations MUST classify payloads using exactly the following steps:

1. Decode CBOR bytes.
2. Value MUST be a map.
3. Map keys MUST be text strings.
4. Extract `type` as required text string.
5. Route to exact type decoder.
6. Unsupported known/unknown future types => `unsupported-safe-skip`; malformed supported types => `reject`.

No alternative classification path is allowed.

- `manifest_id` and all other envelope/protocol metadata MUST NOT be used for payload type inference.
- Heuristic or fallback decoding MUST NOT be used.

## 5. Type registry

Supported payload types in MVP0:

- `wayfarer.chat.v1`
- `wayfarer.media_manifest.v1`

Reserved payload types in MVP0:

- `wayfarer.profile.v1`
- `wayfarer.reaction.v1`
- `wayfarer.message_update.v1`
- `wayfarer.status_event.v1`
- `wayfarer.notice.v1`

All payloads MUST carry top-level `type`.

## 6. Supported payload specifications

### 6.1 `wayfarer.chat.v1`

Purpose: renderable human-readable chat message.

Canonical shape:

```json
{
  "type": "wayfarer.chat.v1",
  "text": "hello wayfarer",
  "created_at_unix_ms": 1735689600000
}
```

Required fields:

- `type`: MUST equal `wayfarer.chat.v1`.
- `text`: UTF-8 string, MUST be non-empty.
- `created_at_unix_ms`: integer milliseconds timestamp.

Unknown keys:

- Unknown keys MUST be ignored.

Identity authority:

- Payload MUST NOT override envelope sender identity.
- If `author_wayfarer_id` appears, it is NON-AUTHORITATIVE and MUST NOT drive attribution or classification.

Outcome:

- Valid payload: `accept/display`.
- Malformed payload (missing/invalid required fields): `reject`.

### 6.2 `wayfarer.media_manifest.v1`

Purpose: app-layer metadata describing media/attachment assets.

This payload is not protocol chunking `ManifestV1`; `transfer_ref` is opaque app data.

Canonical shape:

```json
{
  "type": "wayfarer.media_manifest.v1",
  "transfer_ref": "opaque-transfer-reference",
  "media_kind": "image|video|audio|file",
  "assets": [
    {
      "asset_ref": "opaque-asset-reference",
      "mime_type": "image/jpeg",
      "byte_length": 4096,
      "name": "optional filename"
    }
  ],
  "caption": "optional string",
  "created_at_unix_ms": 1735689601000
}
```

Required fields:

- `type`: MUST equal `wayfarer.media_manifest.v1`.
- `transfer_ref`: non-empty string.
- `media_kind`: one of `image`, `video`, `audio`, `file`.
- `assets`: non-empty array of maps.
- `assets[].asset_ref`: non-empty string.
- `assets[].mime_type`: non-empty string.
- `assets[].byte_length`: integer, MUST be `>= 0`.
- `created_at_unix_ms`: integer milliseconds timestamp.

Optional fields:

- `caption`: UTF-8 string.
- `assets[].name`: UTF-8 string.

Unknown keys:

- Unknown keys MUST be ignored.

Identity authority:

- Payload MUST NOT override envelope sender identity.
- If `author_wayfarer_id` appears, it is NON-AUTHORITATIVE and MUST NOT drive attribution or classification.

Outcome:

- Valid payload: `accept/store-no-display` (default MVP0 behavior).
- Malformed payload (missing/invalid required fields): `reject`.

## 7. Reserved payload semantics

Reserved payloads are intentionally non-renderable in MVP0.

- Reserved minimum shape: `{ "type": "<reserved-type>" }`
- Additional keys MAY appear and MUST NOT cause fallback decode into chat/media.
- Handling for all reserved types: `accept/store-no-display`.

Reserved meanings:

- `wayfarer.profile.v1`: profile metadata evolution.
- `wayfarer.reaction.v1`: reaction/acknowledgement semantics.
- `wayfarer.message_update.v1`: edit/delete/update references.
- `wayfarer.status_event.v1`: durable interaction events (for example read/viewed).
- `wayfarer.notice.v1`: system/app informational notices.

Presence and typing signals remain out of scope for MVP0 and are not covered by `wayfarer.status_event.v1`.

## 8. Malformed vs unsupported distinction (strict)

- **Malformed** applies only after routing to a supported decoder (`wayfarer.chat.v1` or `wayfarer.media_manifest.v1`) when that schema validation fails => `reject`.
- **Unsupported** applies when `type` is unsupported known version or unknown future extension => `unsupported-safe-skip`.
- Unsupported payloads MUST NOT be reinterpreted as malformed supported payloads.

Invalid examples (MUST be handled exactly):

1. `{ "type": "future.poll.v1", "text": "..." }` MUST NOT run chat decoder; outcome `unsupported-safe-skip`.
2. `{ "type": "wayfarer.chat.v1", "text": "", "created_at_unix_ms": "173..." }` is malformed supported chat; outcome `reject`.
3. Non-CBOR bytes, CBOR non-map, or CBOR map with non-text keys => `reject`.

## 9. Outcome vocabulary

- `accept/display`
- `accept/store-no-display`
- `unsupported-safe-skip`
- `reject`

## 10. Non-goals

MVP0 explicitly does **not** include:

- JSON payload support
- Fallback decoding
- Dual-format compatibility paths
- Implicit schema inference

## 11. Conformance requirements

Implementations are conformant only if all requirements below hold:

1. Classification follows Section 4 exactly.
2. `manifest_id` and all non-body metadata are never used for type inference.
3. Chat decoder MUST run only when `type == "wayfarer.chat.v1"`.
4. Unsupported known and unknown future types resolve to `unsupported-safe-skip`.
5. Malformed supported payloads resolve to `reject`.
6. Decode failures (including invalid CBOR/non-map/non-text-key map) resolve to `reject`.
7. Fixture outcomes in `Fixtures/App/wayfarer-payload-taxonomy/` MUST be matched exactly.

## 12. Routing and relay guidance

1. Gossip routing/forwarding is payload-agnostic.
2. Payload taxonomy MUST NOT affect envelope hash/signature checks or other protocol invariants.
3. Forwarding nodes preserve envelope bytes exactly, regardless of payload type support.

## 13. Fixture linkage

Conformance fixtures live at:

- `Fixtures/App/wayfarer-payload-taxonomy/README.md`
- `Fixtures/App/wayfarer-payload-taxonomy/manifest.json`
- `Fixtures/App/wayfarer-payload-taxonomy/*.json`
