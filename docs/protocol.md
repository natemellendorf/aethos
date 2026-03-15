# Aethos Canonical Object Protocol (MVP0)

This document defines canonical object bytes, object identity derivation, and strict decoding rules.

## 1. Scope and authority

- `docs/protocol.md` is authoritative for canonical object encoding/decoding.
- `docs/protocol/frames.md` is authoritative for gossip frame contracts.
- Transport metadata and canonical object data are separate by design.

## 2. Frozen decisions

- Canonical object IDs use SHA-256 over canonical bytes.
- Signatures use Ed25519.
- CBOR is used where profile docs specify CBOR payloads.
- Envelope includes `toWayfarerId` in MVP0.

## 3. Canonical field envelope

Canonical object bytes use this binary format:

- `version`: 1 byte
- `type`: 1 byte
- repeated fields in fixed order:
  - `field_id`: 1 byte
  - `len`: 4 byte big-endian unsigned length
  - `raw`: `len` bytes

Decoders MUST fail closed when:

- required fields are missing,
- required field lengths are malformed,
- field IDs are duplicated,
- unknown structural fields appear,
- protocol version/type is unsupported.

No backward compatibility parsing is defined for author-less message objects.

## 4. Type discriminator allocation and reserved space

- Core object type range: `1...127`
- Reserved future object type range: `128...255`

Currently assigned:

- `1`: envelope
- `2`: manifest
- `3`: message
- `4`: receipt
- `5`: inventory
- `6`: inventory_request
- `7`: sealed_envelope

Unsupported object type values MUST be rejected deterministically.

## 5. Message object contract (breaking v2)

`MessageV1` now has a v2 wire contract and MUST decode only at `version=2`.

Field IDs:

- `1` `createdAtUnixMs` (`Int64`, 8 bytes)
- `2` `authorWayfarerId` (32 raw bytes, required)
- `3` `body` (bytes, required)
- `4` `extensionMetadata` (optional CBOR map)

Canonical author semantics:

- `authorWayfarerId` is the only authoritative sender identity for a message object.
- Transport peer identity (`received_from`, relay peer ID, socket peer, etc.) is metadata only.
- Transport metadata MUST NOT override canonical author attribution.

Hash/signature implications:

- `authorWayfarerId` is inside canonical bytes.
- Changing canonical author changes canonical bytes and therefore object hash/signature material.

## 6. Extensibility discipline

Structural unknowns:

- Unknown structural fields are forbidden and MUST be rejected.

Extension-safe container:

- Unknown keys are only tolerated in `extensionMetadata` (message field `4`).
- `extensionMetadata` MUST be a CBOR map with text keys.

Reserved extension namespaces:

- `aethos.*` reserved for core protocol evolution.
- `sys.*` reserved for runtime/system use.

Payloads using reserved prefixes in `extensionMetadata` MUST be rejected.

## 7. Transport metadata separation

Stores and APIs SHOULD persist both:

- canonical author (`author_wayfarer_id`), and
- transport peer metadata (`received_from_peer_id`) when available.

These values represent different trust domains and MUST remain separate fields.
