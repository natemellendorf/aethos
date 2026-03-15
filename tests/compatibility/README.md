# Protocol Compatibility Harness

This harness validates deterministic protocol artifacts across implementations.

## Covered checks

- Canonical envelope serialization to deterministic CBOR bytes
- `item_id` derivation (`sha256(envelope_bytes)`, lowercase hex)
- Unpadded base64url encoding for `envelope_b64`
- Simple frame encode/decode round-trip validation
- Deterministic repeat-encoding validation
- Transfer behavior simulation (`HELLO -> SUMMARY -> REQUEST -> TRANSFER -> RECEIPT`)

## Runner interface

Each runner must support:

```text
runner encode-envelope <vector-file>
```

and emit JSON:

```json
{
  "canonical_cbor_hex": "...",
  "item_id_hex": "...",
  "envelope_b64": "..."
}
```

## Run

```bash
python3 tests/compatibility/harness.py --verbose
```
