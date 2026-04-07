# BLE identity v1 fixtures

This suite provides conformance vectors for `docs/protocol/ble-identity-v1.md`.

Each fixture file includes:

- `legacyAdvertising.primaryAdvHex`: raw advertising data bytes (AD structures only).
- `legacyAdvertising.scanResponseHex`: raw scan response data bytes (AD structures only).
- `expected`: validation result and parsed field expectations.

## Coverage map

### Valid fixtures

- `valid-stable-lan-mpc.json`: stable identity mode, LAN+MPC capability bits.
- `valid-rotating-private-relay-unknown-cap-bit.json`: rotating/private flags, RELAY capability, unknown capability bit set (must be ignored).
- `valid-all-capabilities.json`: LAN+MPC+RELAY set.

### Invalid fixtures

- `invalid-wrong-service-data-uuid.json`: scan response service-data UUID does not match frozen Aethos UUID.
- `invalid-wrong-primary-uuid.json`: primary advertisement UUID list does not contain frozen Aethos UUID.
- `invalid-missing-primary-uuid-list.json`: primary advertisement omits AD type `0x07` Aethos UUID list.
- `invalid-missing-scan-response-service-data.json`: scan response omits AD type `0x21` service data.
- `invalid-wrong-payload-length.json`: service-data payload is not exactly 12 bytes.
- `invalid-reserved-flag-bit-set.json`: reserved flag bits (2..7) are non-zero.
- `invalid-all-zero-identity-ref.json`: identity reference is all zero bytes.
- `invalid-unsupported-version.json`: unsupported payload version.
