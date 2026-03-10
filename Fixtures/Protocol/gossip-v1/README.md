# Gossip v1 fixtures

This directory contains interoperability fixtures for the Aethos **Gossip Protocol v1**.

## Canonical bytes (authoritative)

All `*.cbor` files in this directory are the **authoritative canonical CBOR bytes** for their corresponding fixture.

- Encoding MUST be canonical (RFC 8949 deterministic encoding).
- These bytes are the wire contract: downstream implementations should decode and re-encode against these bytes to detect drift.

## Fixture shapes

### Positive vectors

Files like `hello.cbor`, `summary.cbor`, `request.cbor`, `transfer.cbor`, `receipt.cbor`, and `relay_ingest.cbor` are valid frame envelopes (see `docs/protocol/frames.md`).

### Negative vectors

Some fixtures are intentionally *invalid at the frame/engine boundary*.

- A negative vector may still be a valid canonical CBOR value, but it is crafted to be rejected by:
  - bearer framing (`GossipV1Framing`), or
  - frame parsing (`GossipV1Frame.decode`), or
  - encounter/engine validation (`GossipV1EncounterEngine`).

For example, `transfer_oversize_bytes.cbor` is valid canonical CBOR, but it must be rejected as an invalid datagram frame because it exceeds the maximum transfer envelope byte budget.

Some negative vectors are defined only by JSON metadata when the raw bytes would be too large to store in-repo (e.g. a datagram exceeding `MAX_FRAME_BYTES` is generated deterministically in tests).

## JSON metadata files

Each `*.json` file is metadata describing the expected result when consuming the corresponding vector (expected error domain/type, or expected effect). Runtime behavior is authoritative; JSON metadata must match the intended boundary and the tests.

## Other files

- `bloom_filter.bin` is a deterministic bloom filter byte vector.
- `item_id_derivation.json` pins `item_id = sha256(envelope_bytes)` derivations for the canonical transfer fixture objects.
