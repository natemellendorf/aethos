# Aethos Protocol v1 (MVP0)

Note: Scope split is strict.
- `docs/spec/*` defines wire-level transports, frames, and protocol semantics.
- `docs/protocol.md` defines core structures and their canonical byte encodings used by those wire contracts.

Timestamp unit convention: canonical fields suffixed `UnixMs` are Unix epoch milliseconds (`UInt64`); some transport metadata in client-relay contracts may use Unix epoch seconds as explicitly specified in those transport docs.

Frozen decisions:
- CBOR for application payload content profiles (schema not defined in this document)
- SHA-256 IDs
- Ed25519 identity + receipt signatures
- 32KB chunks (32768 bytes)
- Envelope contains toWayfarerId (visible in MVP0)

Artifacts:
- EnvelopeV1
- ManifestV1
- ChunkV1
- ReceiptV1

## Canonical Bytes v1

MVP0 uses a deterministic, byte-for-byte stable encoding for computing IDs.

Encoding (per message):
- `v`: 1 byte protocol version (currently `1`)
- `t`: 1 byte type discriminator
- Then a sequence of fields in stable order:
  - `fieldId`: 1 byte
  - `len`: 4 bytes big-endian `UInt32`
  - `raw`: `len` bytes

Integer raw encodings:
- Timestamps: big-endian fixed-width `UInt64`
- Array counts: big-endian fixed-width `UInt32`

Optional fields:
- Always present; when nil, encode `len = 0` and no `raw` bytes.

Arrays (`[Data]`) inside a field's `raw` bytes:
- `count`: `UInt32`
- For each item: `[len: UInt32][bytes]`

Type discriminators:
- EnvelopeV1: `1`
- ManifestV1: `2`
- ReceiptV1: `4`

### EnvelopeV1 Canonical Fields

Field ids (in order):
- `1` toWayfarerId (bytes, exactly 32 raw bytes)
- `2` manifestId (bytes)
- `3` body (bytes)

### ManifestV1 Canonical Fields

Field ids (in order):
- `1` totalSize (`UInt64` raw)
- `2` chunkIds (`[Data]` raw array encoding)

### ReceiptV1 Canonical Fields

Field ids (in order):
- `1` envelopeId (bytes)
- `2` manifestId (bytes)
- `3` receivedAtUnixMs (`UInt64` raw)
- `4` signature (bytes, optional; present with `len=0` when nil)
