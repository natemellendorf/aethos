# WAYFARER_COMPATIBILITY_MATRIX

Status: App payload compatibility matrix (MVP0)

This matrix defines required handling behavior for Wayfarer payload types across implementation capability states.

Contract reference: `docs/app/WAYFARER_PAYLOAD_CONTRACT.md`

**Matrix is executable interpretation of contract.**

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
| Unknown future type (for example `future.poll.v1`) | Future/extension | Unsupported | `unsupported-safe-skip` | MUST NOT fallback-decode as `wayfarer.chat.v1`, even if fields resemble chat. |

## 3. Decoder guard matrix

| Condition | Required guard | Outcome |
| --- | --- | --- |
| Body is non-deterministic CBOR (decodable but not RFC 8949 deterministic form) | Reject at classification boundary before type routing | `reject` |
| Any map (top-level or nested) contains duplicate keys | Reject at classification boundary before type routing | `reject` |
| Top-level `type` missing or non-text | Reject at classification boundary before type routing | `reject` |
| Envelope accepted, body decode yields unsupported `type` | Do not run supported-type decoders | `unsupported-safe-skip` |
| Envelope accepted, `type=wayfarer.chat.v1`, schema invalid | Reject known-type malformed payload | `reject` |
| Envelope accepted, `type=wayfarer.media_manifest.v1`, schema invalid | Reject known-type malformed payload | `reject` |
| `type` is not `wayfarer.chat.v1` | Chat decoder MUST NOT run | Not `accept/display` via chat |
| `type` is reserved (`wayfarer.*.v1` reserved set) | Do not render; optional durable store | `accept/store-no-display` |
| Body bytes fail app decode requirements (for example invalid/non-deterministic CBOR, duplicate map keys, decoded non-map, or non-text top-level map keys) | Do not run type-specific decoders | `reject` |
| Unknown keys appear in nested supported structures | Ignore unknown keys; continue schema checks for required fields | Classification outcome unchanged by unknown keys |
| Type mismatch (payload shape resembles chat but `type` differs) | Route by `type`; no heuristic fallback | `unsupported-safe-skip` |

Malformed vs unsupported rule:

- Malformed = schema-invalid after routing to a supported decoder (`wayfarer.chat.v1`, `wayfarer.media_manifest.v1`) => `reject`.
- Unsupported = unsupported known or unknown future `type` after successful classification => `unsupported-safe-skip`.
- Decode-failure at classification boundary (invalid/non-deterministic CBOR, duplicate map keys at any map depth, non-map top-level value, non-text-key top-level map, or missing/non-text `type`) => `reject`.

## 4. Fixture coverage mapping

| Fixture | Payload type | Expected outcome | Purpose |
| --- | --- | --- | --- |
| `valid_wayfarer_chat_v1.json` | `wayfarer.chat.v1` | `accept/display` | Happy-path renderable chat payload. |
| `valid_wayfarer_media_manifest_v1.json` | `wayfarer.media_manifest.v1` | `accept/store-no-display` | Happy-path media metadata payload. |
| `malformed_wayfarer_chat_v1.json` | `wayfarer.chat.v1` | `reject` | Known-type malformed payload rejection. |
| `unknown_future_payload_type_v1.json` | unknown future `type` | `unsupported-safe-skip` | Forward compatibility without chat misdecode. |
| `unsupported_known_wayfarer_chat_v2.json` | known future `type` (`wayfarer.chat.v2`) | `unsupported-safe-skip` | Known future version is unsupported-safe-skip, not malformed v1 chat. |
| `binary_non_utf8_body.json` | body bytes failing app decode requirements | `reject` | Reject invalid CBOR/decoded non-map/non-text top-level map key bodies before typed decoders. |
| `nondeterministic_but_decodable_cbor.json` | non-deterministic CBOR body | `reject` | Reject decodable bytes that violate RFC 8949 deterministic form. |
| `duplicate_top_level_key.json` | duplicate top-level map key | `reject` | Reject duplicate keys at top-level classification map. |
| `duplicate_nested_key.json` | duplicate nested map key | `reject` | Reject duplicate keys in nested map before reserved/supported handling. |
| `missing_top_level_type.json` | missing top-level `type` | `reject` | Reject when required `type` discriminator is absent. |
| `non_string_top_level_type.json` | non-text top-level `type` | `reject` | Reject when top-level `type` is not a CBOR text string. |
| `top_level_non_map.json` | top-level non-map | `reject` | Reject when decoded top-level CBOR value is not a map. |
| `malformed_wayfarer_media_manifest_v1.json` | `wayfarer.media_manifest.v1` | `reject` | Supported media payload with invalid schema is malformed and rejected. |
| `valid_wayfarer_chat_v1_with_unknown_keys.json` | `wayfarer.chat.v1` | `accept/display` | Unknown keys (including nested) do not affect classification/outcome. |
| `negative_timestamp_wayfarer_chat_v1.json` | invalid timestamp domain | `reject` | Reject negative `created_at_unix_ms`. |
| `out_of_range_timestamp_wayfarer_chat_v1.json` | invalid timestamp range | `reject` | Reject `created_at_unix_ms` outside shared runtime numeric range. |
| `negative_byte_length_wayfarer_media_manifest_v1.json` | invalid media asset length domain | `reject` | Reject negative `assets[].byte_length`. |
| `out_of_range_byte_length_wayfarer_media_manifest_v1.json` | invalid media asset length range | `reject` | Reject `assets[].byte_length` outside implementation numeric range. |
| `reserved_wayfarer_profile_v1_with_additional_keys.json` | `wayfarer.profile.v1` | `accept/store-no-display` | Reserved payload accepts additional keys after base gates succeed. |
| `reserved_wayfarer_profile_v1.json` | `wayfarer.profile.v1` | `accept/store-no-display` | Reserved profile placeholder. |
| `reserved_wayfarer_reaction_v1.json` | `wayfarer.reaction.v1` | `accept/store-no-display` | Reserved reaction placeholder. |
| `reserved_wayfarer_message_update_v1.json` | `wayfarer.message_update.v1` | `accept/store-no-display` | Reserved message update placeholder. |
| `reserved_wayfarer_status_event_v1.json` | `wayfarer.status_event.v1` | `accept/store-no-display` | Reserved status event placeholder. |
| `reserved_wayfarer_notice_v1.json` | `wayfarer.notice.v1` | `accept/store-no-display` | Reserved notice placeholder. |

Fixture source of truth: `Fixtures/App/wayfarer-payload-taxonomy/manifest.json`.

## 5. Conformance gates

An implementation is MVP0-compatible when all fixture expected outcomes are matched exactly and no unsupported payload is mis-decoded as chat.

Additional hard gates:

1. Classification MUST begin from fixture `body_cbor_hex` bytes.
2. When `expected_decoded_map` is present, it is a REQUIRED SUBSET assertion over the decoded authoritative top-level map (not a complete-map assertion).
3. Subset comparison is deep-recursive for nested maps; arrays in `expected_decoded_map` are exact assertions and MUST match decoded arrays exactly (length, order, values).
4. For every key/value in `expected_decoded_map`, decoded output MUST contain exactly equal value for that assertion path.
5. Additional decoded keys, including unknown keys, are tolerated and MUST NOT fail conformance.
6. Runners MUST decode from authoritative `body_cbor_hex` and MUST NOT use `expected_decoded_map` as input.
7. Chat decoder MUST run only for `type=wayfarer.chat.v1`.
8. Decode-failure fixtures (invalid bytes, non-deterministic bytes, or duplicate-key bytes) MUST reject without typed decoder execution.
