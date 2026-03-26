# WAYFARER_COMPATIBILITY_MATRIX

Status: App payload compatibility matrix (MVP0)

This matrix defines required handling behavior for Wayfarer payload families across implementation capability states.

Contract reference: `docs/app/WAYFARER_PAYLOAD_CONTRACT.md`

## 1. Outcome vocabulary

- `accept/display`
- `accept/store-no-display`
- `unsupported-safe-skip`
- `reject`

## 2. Payload family matrix

| Payload family | Declared status | Decoder support state | Expected outcome | Notes |
| --- | --- | --- | --- | --- |
| `chat.v1` | Active | Supported + valid | `accept/display` | Renderable user-visible message payload. |
| `chat.v1` | Active | Supported + malformed | `reject` | Known-family strict decode failure is fail-closed. |
| `media_manifest.v1` | Active | Supported + valid | `accept/store-no-display` | Stored for media workflows; default MVP0 non-rendering. |
| `media_manifest.v1` | Active | Supported + malformed | `reject` | Known-family strict decode failure is fail-closed. |
| Unknown future family (for example `future.poll.v1`) | Future/extension | Unsupported | `unsupported-safe-skip` | MUST NOT fallback-decode as `chat.v1`. |
| `reserved.system.*` | Reserved | Unsupported/disabled | `accept/store-no-display` | Reserved non-renderable scope in MVP0. |
| `reserved.control.*` | Reserved | Unsupported/disabled | `accept/store-no-display` | Reserved non-renderable scope in MVP0. |

## 3. Decoder guard matrix

| Condition | Required guard | Outcome |
| --- | --- | --- |
| Envelope accepted, manifest mapping unknown | Do not run known-family decode | `unsupported-safe-skip` |
| Envelope accepted, manifest maps to `chat.v1`, schema invalid | Reject known-family malformed payload | `reject` |
| Envelope accepted, manifest maps to `media_manifest.v1`, schema invalid | Reject known-family malformed payload | `reject` |
| Manifest does not map to `chat.v1` | Chat decoder MUST NOT run | Not `accept/display` via chat |
| Payload family reserved | Do not render; optional durable store | `accept/store-no-display` |

## 4. Fixture coverage mapping

| Fixture | Family | Expected outcome | Purpose |
| --- | --- | --- | --- |
| `valid_chat_v1.json` | `chat.v1` | `accept/display` | Happy-path renderable chat payload. |
| `valid_media_manifest_v1.json` | `media_manifest.v1` | `accept/store-no-display` | Happy-path media metadata payload. |
| `malformed_chat_v1.json` | `chat.v1` | `reject` | Known-family malformed payload rejection. |
| `unknown_future_payload_v1.json` | unknown future | `unsupported-safe-skip` | Forward compatibility without misdecode. |
| `reserved_system_placeholder_v1.json` | `reserved.system.*` | `accept/store-no-display` | Reserved-system family placeholder. |
| `reserved_control_placeholder_v1.json` | `reserved.control.*` | `accept/store-no-display` | Reserved-control family placeholder. |

Fixture source of truth: `Fixtures/App/wayfarer-payload-taxonomy/manifest.json`.

## 5. Conformance gates

An implementation is MVP0-compatible when all fixture expected outcomes are matched exactly and no unsupported payload is mis-decoded as chat.
