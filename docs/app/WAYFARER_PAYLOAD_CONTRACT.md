# WAYFARER_PAYLOAD_CONTRACT

Status: Canonical app payload contract for Wayfarer-facing payload taxonomy (MVP0)

This document defines how application payload bytes inside gossip envelopes are interpreted, versioned, and handled by Wayfarer clients.

- Transport-neutral envelope contract: `docs/protocol/frames.md` (§5.4.1)
- Gossip protocol invariants: `docs/protocol/gossip.md`
- Wire/API transport contracts: `docs/spec/*`

## 1. Scope and authority boundaries

1. Gossip frame parsing, envelope validation, hashing, and signature verification are owned by the protocol layer.
2. Payload taxonomy dispatch (`chat`, `media_manifest`, unknown, reserved) is owned by the app payload layer.
3. UI rendering policy is owned by app product layers and MUST consume only typed payload decode results from this contract.
4. Unknown or unsupported payload families MUST NOT be treated as protocol errors if envelope-level validation succeeded.

Boundary rule:

- Envelope validity answers: "Is this object authentic and well-formed for gossip transport?"
- Payload taxonomy answers: "What does this object mean to the app?"

These are separate decisions and MUST remain separate in implementations.

## 2. Encoding and framing prerequisites

1. Gossip transfer envelope bytes MUST remain canonical deterministic CBOR per `docs/protocol/frames.md`.
2. Envelope body is opaque bytes at protocol level (`body: bstr`).
3. The payload taxonomy in this document applies only after envelope-level acceptance.
4. Implementations MAY represent decoded payloads internally as typed structs; on-wire payload bytes remain opaque to protocol framing.

## 3. Taxonomy model

Payload classification is keyed by `manifest_id` with deterministic mapping to a payload family and schema version.

For MVP0 this contract fixes these families:

- `chat.v1` (active)
- `media_manifest.v1` (active)
- `reserved.system.*` (reserved)
- `reserved.control.*` (reserved)

### 3.1 Manifest authority

1. `manifest_id` is authoritative for payload classification.
2. Implementations MUST NOT infer payload family from body shape alone.
3. If manifest mapping is unknown locally, payload handling outcome is `unsupported-safe-skip`.

### 3.2 Reserved namespace scoping

1. `reserved.system.*` is reserved for core/runtime evolution.
2. `reserved.control.*` is reserved for control-plane evolution.
3. Reserved families are intentionally non-renderable in MVP0.
4. Receiving reserved-family payloads with valid envelopes MUST result in `accept/store-no-display` unless local policy explicitly disables storage.

## 4. Canonical active payload families (MVP0)

## 4.1 `chat.v1`

Purpose: human-readable user message payload.

Canonical decoded shape:

```json
{
  "type": "chat.v1",
  "text": "string (UTF-8, non-empty)",
  "created_at_unix_ms": 1735689600000,
  "author_wayfarer_id": "64-char lowercase hex"
}
```

Normative rules:

1. `type` MUST equal `chat.v1`.
2. `text` MUST be valid UTF-8 and MUST be non-empty after Unicode scalar decoding.
3. `created_at_unix_ms` MUST be an integer timestamp in milliseconds.
4. `author_wayfarer_id` MUST be exactly 64 lowercase hex characters.
5. `author_wayfarer_id` MUST equal the canonical sender identity derived by protocol rules for the enclosing envelope.
6. If any required field is missing or invalid, handling outcome MUST be `reject`.

## 4.2 `media_manifest.v1`

Purpose: metadata for media content composed of chunked objects.

Canonical decoded shape:

```json
{
  "type": "media_manifest.v1",
  "media_kind": "image|video|audio|file",
  "mime_type": "string",
  "byte_length": 12345,
  "chunk_ids": ["64-char lowercase hex", "..."],
  "caption": "optional string",
  "created_at_unix_ms": 1735689600000,
  "author_wayfarer_id": "64-char lowercase hex"
}
```

Normative rules:

1. `type` MUST equal `media_manifest.v1`.
2. `media_kind` MUST be one of `image`, `video`, `audio`, `file`.
3. `mime_type` MUST be a non-empty string.
4. `byte_length` MUST be a non-negative integer.
5. `chunk_ids` MUST contain at least one item.
6. Every `chunk_ids[]` entry MUST be exactly 64 lowercase hex characters.
7. `created_at_unix_ms` and `author_wayfarer_id` rules match `chat.v1`.
8. If required fields are missing or malformed, handling outcome MUST be `reject`.
9. On successful decode, default handling outcome is `accept/store-no-display` unless a client has explicit media UI support.

## 5. Cross-cutting handling rules

1. Fail closed on malformed payloads in known families (`chat.v1`, `media_manifest.v1`) with outcome `reject`.
2. Fail open-safe for unknown future families with outcome `unsupported-safe-skip`.
3. Unsupported payloads MUST NOT be reinterpreted as `chat.v1` by heuristics, fallback text parsing, or field guessing.
4. Dispatch MUST be keyed by authoritative manifest mapping before family-specific decoding.
5. Display eligibility requires both:
   - successful family decode, and
   - family marked renderable for current product surface.

Anti-misdecode rule (normative):

- Implementations MUST NOT attempt `chat.v1` decode unless manifest mapping declares the payload family as `chat.v1`.

## 6. Inbound handling contract

Each accepted envelope maps to exactly one handling outcome:

- `accept/display`: accepted, persisted, and eligible for user-visible rendering.
- `accept/store-no-display`: accepted and persisted, but intentionally not rendered.
- `unsupported-safe-skip`: envelope accepted; payload family unknown/unsupported; safely skipped for rendering.
- `reject`: payload invalid for declared known family; object rejected at payload layer.

Deterministic inbound flow:

1. Validate frame/envelope/signature/hash at protocol layer.
2. Resolve manifest mapping to payload family.
3. If family unknown: return `unsupported-safe-skip`.
4. If family known: run strict schema decode for that family.
5. If decode fails: return `reject`.
6. If decode succeeds: return family default outcome (`chat.v1` -> `accept/display`; `media_manifest.v1` -> `accept/store-no-display`).

## 7. Conformance expectations

Implementations are conformant when they satisfy all of the following:

1. Enforce manifest-authoritative dispatch.
2. Enforce anti-misdecode rule (unknown/unsupported never decoded as chat).
3. Emit one of the four handling outcomes deterministically.
4. Pass fixture vectors in `Fixtures/App/wayfarer-payload-taxonomy/`.
5. Preserve protocol-layer acceptance/rejection semantics independent from payload-layer outcomes.

## 8. Routing and relay guidance

1. Routing and gossip forwarding are payload-agnostic: relays and forwarders MUST treat envelope bytes as opaque payload carrier bytes.
2. Payload taxonomy MUST NOT influence envelope hash, signature checks, TTL/expiry checks, or hop-count invariants.
3. Nodes MAY use payload family only for local product policy (rendering/storage prioritization), never for mutating envelope content.
4. Forwarding nodes MUST preserve envelope bytes exactly, regardless of payload family support.

## 9. Fixture linkage

Conformance fixtures for this contract live at:

- `Fixtures/App/wayfarer-payload-taxonomy/README.md`
- `Fixtures/App/wayfarer-payload-taxonomy/manifest.json`
- `Fixtures/App/wayfarer-payload-taxonomy/*.json`

Expected outcomes and fixture semantics are normative for MVP0 conformance.
