# WAYFARER_COMPATIBILITY_MATRIX

Status: App payload compatibility matrix (MVP0)

This matrix defines required handling behavior for Wayfarer payload types across implementation capability states.

Contract reference: `docs/app/WAYFARER_PAYLOAD_CONTRACT.md`

## 1. Outcome vocabulary

- `accept/display`
- `accept/store-no-display`
- `unsupported-safe-skip`
- `reject`

## 2. Payload type matrix

| Payload type | Declared status | Decoder support state | Expected outcome | Notes |
| --- | --- | --- | --- | --- |
| `wayfarer.chat.v1` | Active | Supported + valid | `accept/display` | Renderable user-visible message payload. |
| `wayfarer.chat.v1` | Active | Supported + malformed | `reject` | Known supported type strict decode failure is fail-closed. |
| `wayfarer.media_manifest.v1` | Active | Supported + valid | `accept/store-no-display` | Stored for media workflows; default MVP0 non-rendering. |
| `wayfarer.media_manifest.v1` | Active | Supported + malformed | `reject` | Known supported type strict decode failure is fail-closed. |
| `wayfarer.profile.v1` | Reserved | Not implemented | `accept/store-no-display` | Reserved non-renderable scope in MVP0. |
| `wayfarer.reaction.v1` | Reserved | Not implemented | `accept/store-no-display` | Reserved non-renderable scope in MVP0. |
| `wayfarer.message_update.v1` | Reserved | Not implemented | `accept/store-no-display` | Reserved non-renderable scope in MVP0. |
| `wayfarer.status_event.v1` | Reserved | Not implemented | `accept/store-no-display` | Reserved non-renderable scope in MVP0. |
| `wayfarer.notice.v1` | Reserved | Not implemented | `accept/store-no-display` | Reserved non-renderable scope in MVP0. |
| Unsupported known version (for example `wayfarer.chat.v2`) | Future known | Unsupported | `unsupported-safe-skip` | Unsupported known type is not malformed chat. |
| Unknown future type (for example `future.poll.v1`) | Future/extension | Unsupported | `unsupported-safe-skip` | MUST NOT fallback-decode as `wayfarer.chat.v1`. |

## 3. Decoder guard matrix

| Condition | Required guard | Outcome |
| --- | --- | --- |
| Envelope accepted, body decode yields unsupported `type` | Do not run supported-type decoders | `unsupported-safe-skip` |
| Envelope accepted, `type=wayfarer.chat.v1`, schema invalid | Reject known-type malformed payload | `reject` |
| Envelope accepted, `type=wayfarer.media_manifest.v1`, schema invalid | Reject known-type malformed payload | `reject` |
| `type` is not `wayfarer.chat.v1` | Chat decoder MUST NOT run | Not `accept/display` via chat |
| `type` is reserved (`wayfarer.*.v1` reserved set) | Do not render; optional durable store | `accept/store-no-display` |
| Body is binary/non-UTF8/non-map | Do not run type-specific decoders | `reject` |
| Type mismatch (payload shape resembles chat but `type` differs) | Route by `type`; no heuristic fallback | `unsupported-safe-skip` |

## 4. Fixture coverage mapping

| Fixture | Payload type | Expected outcome | Purpose |
| --- | --- | --- | --- |
| `valid_wayfarer_chat_v1.json` | `wayfarer.chat.v1` | `accept/display` | Happy-path renderable chat payload. |
| `valid_wayfarer_media_manifest_v1.json` | `wayfarer.media_manifest.v1` | `accept/store-no-display` | Happy-path media metadata payload. |
| `malformed_wayfarer_chat_v1.json` | `wayfarer.chat.v1` | `reject` | Known-type malformed payload rejection. |
| `unknown_future_payload_type_v1.json` | unknown future `type` | `unsupported-safe-skip` | Forward compatibility without chat misdecode. |
| `binary_non_utf8_body.json` | invalid body bytes | `reject` | Reject non-UTF8/non-map body before typed decoders. |
| `reserved_wayfarer_profile_v1.json` | `wayfarer.profile.v1` | `accept/store-no-display` | Reserved profile placeholder. |
| `reserved_wayfarer_reaction_v1.json` | `wayfarer.reaction.v1` | `accept/store-no-display` | Reserved reaction placeholder. |
| `reserved_wayfarer_message_update_v1.json` | `wayfarer.message_update.v1` | `accept/store-no-display` | Reserved message update placeholder. |
| `reserved_wayfarer_status_event_v1.json` | `wayfarer.status_event.v1` | `accept/store-no-display` | Reserved status event placeholder. |
| `reserved_wayfarer_notice_v1.json` | `wayfarer.notice.v1` | `accept/store-no-display` | Reserved notice placeholder. |

Fixture source of truth: `Fixtures/App/wayfarer-payload-taxonomy/manifest.json`.

## 5. Conformance gates

An implementation is MVP0-compatible when all fixture expected outcomes are matched exactly and no unsupported payload is mis-decoded as chat.
