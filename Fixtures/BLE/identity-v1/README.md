# BLE identity v1 fixtures

This suite provides conformance vectors for `docs/protocol/ble-identity-v1.md`.

Each fixture file includes:

- `legacyAdvertising.primaryAdvHex`: raw advertising data bytes (AD structures only).
- `legacyAdvertising.scanResponseHex`: raw scan response data bytes (AD structures only).
- `expected`: validation result and parsed field expectations.

## Coverage map

### Valid fixtures

- `valid-stable-lan-mpc.json`: stable identity mode, LAN+MPC capability bits.
- `valid-scanner-tolerates-unknown-capability-bit.json`: scanner-tolerance case with unknown capability bit set (accepted for forward compatibility; unknown meaning ignored).
- `valid-all-capabilities.json`: LAN+MPC+RELAY set.
- `valid-multi-uuid-list-includes-aethos.json`: AD type `0x07` carries multiple UUIDs and includes Aethos UUID.

### Invalid fixtures

- `invalid-wrong-service-data-uuid.json`: scan response service-data UUID does not match frozen Aethos UUID.
- `invalid-wrong-primary-uuid.json`: primary advertisement UUID list does not contain frozen Aethos UUID.
- `invalid-missing-primary-uuid-list.json`: primary advertisement omits AD type `0x06`/`0x07` UUID list containing Aethos UUID.
- `invalid-missing-identity-service-data.json`: neither primary nor scan response carries Aethos AD type `0x21` service data.
- `invalid-wrong-payload-length.json`: service-data payload is not exactly 12 bytes.
- `invalid-reserved-flag-bit-set.json`: reserved flag bits (2..7) are non-zero.
- `invalid-all-zero-identity-ref.json`: identity reference is all zero bytes.
- `invalid-unsupported-version.json`: unsupported payload version.
- `invalid-multiple-aethos-service-data-in-scan-response.json`: duplicate Aethos AD type `0x21` in one PDU.
- `invalid-mismatched-service-data-between-primary-and-scan-response.json`: Aethos AD type `0x21` appears in both PDUs but payload bytes differ.

### Derivation vectors

- `vector-stable-derivation.json`: stable derivation (`SHA-256(context || wayfarer_id_bytes)`, truncated to 8 bytes).
- `vector-rotating-derivation.json`: rotating derivation (`HMAC-SHA256(k_ble, context || LE64(epoch))`, truncated to 8 bytes).
