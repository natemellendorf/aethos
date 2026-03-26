# WAYFARER_PAYLOAD_CONTRACT

Status: Canonical app payload contract for Wayfarer app-layer payload semantics (MVP0)

This document defines how Wayfarer apps interpret `Envelope.body` bytes after protocol-layer envelope acceptance.

- Transport-neutral envelope contract: `docs/protocol/frames.md` (§5.4.1)
- Gossip protocol invariants: `docs/protocol/gossip.md`
- Wire/API transport contracts: `docs/spec/*`

## 1. Scope and authority boundaries

1. Frame parsing, envelope validation, hash/signature verification, and forwarding are protocol-layer responsibilities.
2. `Envelope.body: bstr` remains opaque at protocol layer.
3. This contract defines only app-layer semantics of those body bytes for Wayfarer clients.
4. Payload handling outcomes are app-layer decisions and MUST NOT mutate protocol validity decisions.

Boundary rule:

- Protocol asks: "Is this envelope authentic and transport-valid?"
- App taxonomy asks: "What payload `type` does this body represent, and how should clients handle it?"

These decisions MUST remain separate.

## 2. App-layer encoding semantics for `Envelope.body`

After protocol-layer acceptance, Wayfarer clients MUST interpret `Envelope.body` as follows:

1. Body bytes MUST be deterministic CBOR (RFC 8949 deterministic encoding).
2. The CBOR top-level item MUST be a map.
3. All map keys MUST be CBOR text strings.
4. The decoded map MUST include top-level `type` with CBOR text string value.
5. All string values are UTF-8 text strings.
6. Unknown keys MUST be ignored by type-specific decoders.
7. Clients SHOULD preserve raw body bytes when persisting accepted/unsupported payloads.

If body bytes are not decodable into the required map shape, outcome is `reject`.

## 3. Type system and classification

### 3.1 Canonical type names

Active supported payload types in MVP0:

- `wayfarer.chat.v1`
- `wayfarer.media_manifest.v1`

Reserved payload types in MVP0:

- `wayfarer.profile.v1`
- `wayfarer.reaction.v1`
- `wayfarer.message_update.v1`
- `wayfarer.status_event.v1`
- `wayfarer.notice.v1`

Cross-cutting rule: every payload MUST carry top-level `type`.

### 3.2 Classification-before-decode rule

Classification is performed by minimal decode of `Envelope.body` to read `type`.

Normative flow:

1. Decode body to CBOR map with text keys.
2. Read `type` string.
3. Route to type-specific decode/validation based on `type`.

`manifest_id` (or any protocol metadata) is NOT authoritative for app payload typing and MUST NOT be used as the app payload discriminator.

### 3.3 Unsupported type rules

1. Unsupported known types (for example `wayfarer.chat.v2`) are `unsupported-safe-skip`.
2. Unknown future types (for example `future.poll.v1`) are `unsupported-safe-skip`.
3. Unsupported known types and unknown future types MUST NOT be treated as malformed `wayfarer.chat.v1`.
4. Clients MUST NOT run chat/media decoders when `type` is not that exact supported type.

## 4. Supported payload type specifications

## 4.1 `wayfarer.chat.v1`

Purpose: renderable human-readable chat message.

Canonical shape:

```json
{
  "type": "wayfarer.chat.v1",
  "text": "hello wayfarer",
  "created_at_unix_ms": 1735689600000,
  "author_wayfarer_id": "64-char lowercase hex"
}
```

Required fields and validation:

- `type`: MUST equal `wayfarer.chat.v1`.
- `text`: UTF-8 string, MUST be non-empty.
- `created_at_unix_ms`: integer timestamp (milliseconds).
- `author_wayfarer_id`: exactly 64 lowercase hex characters.
- `author_wayfarer_id` MUST match canonical sender identity derived from envelope/authorship rules.

Optional fields:

- No additional standardized optional keys in MVP0.
- Unknown keys are allowed and MUST be ignored.

Display/storage behavior:

- Valid payload outcome: `accept/display`.
- Clients SHOULD persist raw body bytes and MAY persist normalized typed projections.

Malformed handling:

- Missing required fields, wrong types, or failed validation => `reject`.

Compatibility expectations:

- Forward-compatible clients ignore unknown keys.
- `wayfarer.chat.v2` (unsupported known version) is `unsupported-safe-skip`, not malformed chat.
- Unknown future types are `unsupported-safe-skip`, not malformed chat.

## 4.2 `wayfarer.media_manifest.v1`

Purpose: app-layer metadata describing media/attachment assets.

Important: this payload is not protocol chunking `ManifestV1`. Any transport reference here is opaque app data.

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
  "created_at_unix_ms": 1735689601000,
  "author_wayfarer_id": "64-char lowercase hex"
}
```

Required fields and validation:

- `type`: MUST equal `wayfarer.media_manifest.v1`.
- `transfer_ref`: non-empty string (opaque; no chunking semantics defined here).
- `media_kind`: one of `image`, `video`, `audio`, `file`.
- `assets`: non-empty array of maps.
- For each `assets[]` item:
  - `asset_ref`: non-empty string.
  - `mime_type`: non-empty string.
  - `byte_length`: integer, MUST be `>= 0`.
- `created_at_unix_ms`: integer timestamp (milliseconds).
- `author_wayfarer_id`: exactly 64 lowercase hex characters and MUST match canonical sender identity.

Optional fields:

- `caption`: optional UTF-8 string.
- `assets[].name`: optional UTF-8 string.
- Unknown keys are allowed and MUST be ignored.

Display/storage behavior:

- Valid payload default outcome: `accept/store-no-display`.
- Products with explicit media UI support MAY render after successful decode.

Malformed handling:

- Missing required fields, wrong types, or failed validation => `reject`.

Compatibility expectations:

- Forward-compatible clients ignore unknown keys.
- `wayfarer.media_manifest.v2` (unsupported known version) is `unsupported-safe-skip`.
- Unknown future types are `unsupported-safe-skip`.

## 5. Reserved payload types

Reserved types are intentionally non-renderable in MVP0. They are not malformed when they satisfy base body requirements (`type` present, map/text-key shape valid).

For each reserved type below, minimum shape is:

```json
{
  "type": "<reserved-type>",
  "data": {}
}
```

Safe handling for all reserved types:

- Outcome: `accept/store-no-display`.
- MUST NOT be rendered as chat/media.
- Unknown keys ignored; raw body SHOULD be preserved if stored.

### 5.1 `wayfarer.profile.v1`

Reserved for profile metadata evolution.

### 5.2 `wayfarer.reaction.v1`

Reserved for reaction/acknowledgement semantics.

### 5.3 `wayfarer.message_update.v1`

Reserved for edit/delete/update references to prior messages.

### 5.4 `wayfarer.status_event.v1`

Reserved for presence/status signaling.

### 5.5 `wayfarer.notice.v1`

Reserved for system/app informational notices.

## 6. Inbound handling contract

Outcome vocabulary:

- `accept/display`
- `accept/store-no-display`
- `unsupported-safe-skip`
- `reject`

Required client behavior:

| Inbound case | Required behavior | Outcome |
| --- | --- | --- |
| Supported `wayfarer.chat.v1` and valid | Decode + validate + render-eligible + persist | `accept/display` |
| Supported `wayfarer.media_manifest.v1` and valid | Decode + validate + persist; default non-rendering | `accept/store-no-display` |
| Reserved type (`wayfarer.profile.v1`, `wayfarer.reaction.v1`, `wayfarer.message_update.v1`, `wayfarer.status_event.v1`, `wayfarer.notice.v1`) | Do not render; optional durable persistence | `accept/store-no-display` |
| Unsupported known payload type (for example `wayfarer.chat.v2`) | Skip type-specific decoder; keep protocol acceptance separate | `unsupported-safe-skip` |
| Unknown future payload type (for example `future.poll.v1`) | Skip safely; do not fallback-decode as chat/media | `unsupported-safe-skip` |
| Malformed payload (type-specific validation failure for supported type) | Fail closed at payload layer | `reject` |
| Binary / non-UTF8 / non-map body bytes | Do not run chat/media decoders | `reject` |

## 7. Conformance expectations

Implementations are conformant when they satisfy all of the following:

1. App classification uses decoded `type`, not `manifest_id`.
2. All payloads require top-level `type`.
3. Unknown keys are ignored by decoders.
4. Unsupported known and unknown future types are `unsupported-safe-skip`.
5. Supported malformed types are `reject`.
6. Fixture expectations in `Fixtures/App/wayfarer-payload-taxonomy/` are matched exactly.

## 8. Routing and relay guidance

1. Gossip routing/forwarding is payload-agnostic.
2. Payload taxonomy MUST NOT affect envelope hash/signature checks or other protocol invariants.
3. Forwarding nodes preserve envelope bytes exactly, regardless of payload type support.

## 9. Fixture linkage

Conformance fixtures live at:

- `Fixtures/App/wayfarer-payload-taxonomy/README.md`
- `Fixtures/App/wayfarer-payload-taxonomy/manifest.json`
- `Fixtures/App/wayfarer-payload-taxonomy/*.json`
