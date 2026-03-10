# Gossip v1 fixtures

This directory is for downstream client interoperability fixtures for the Aethos gossip protocol **v1**.

## Directory contents

- `hello.cbor` / `summary.cbor` / `request.cbor` / `transfer.cbor` / `receipt.cbor` / `relay_ingest.cbor`
  - Intended to contain the canonical CBOR bytes for a single frame envelope (see `docs/protocol/frames.md`).
  - Currently placeholders until canonical CBOR encoding is finalized in code.

- `bloom_filter.bin`
  - Intended to contain exactly 2048 bloom bytes for a deterministic item set.
  - Currently placeholder.

- `item_id_derivation.json`
  - Intended to pin `item_id = sha256(envelope_bytes)` derivations for canonical test vectors.
  - Currently placeholder.

## Notes

All fixtures are **authoritative-spec** aligned. Legacy wire shapes are intentionally not preserved.
