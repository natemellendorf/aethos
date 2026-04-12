# ADR: BLE Identity V2 — Discovery-Only Wakeup Hint Model

- Status: Accepted
- Date: 2026-04-11
- Supersedes: ADR-BLE-IDENTITY-CONTRACT.md (BLE Discovery Identity Contract v1)

## Context

BLE Identity V1 (`docs/protocol/ble-identity-v1.md`) couples Bluetooth advertisement to peer identity by embedding a 12-byte identity payload (version, flags, capabilities, `identity_ref`) inside AD type `0x21` service data. In practice this coupling fails across every major platform:

1. **iOS** rotates BLE peripheral addresses unpredictably and may suppress or reorder scan-response data, making stable `identity_ref` derivation unreliable.
2. **Android** background advertising is throttled or silently dropped by OEM power-management policies, causing identity payloads to vanish for minutes at a time.
3. **General BLE** constraints mean peripherals cannot guarantee that identity fields survive the 31-byte legacy PDU budget, especially when other services share advertisement space.

The result is phantom peers (stale `identity_ref` values that no longer correspond to a reachable node), missed encounters (valid peers whose identity payload was stripped or never delivered), and a growing set of platform-specific workarounds that violate the protocol's own fail-closed invariants.

V1's core assumption — that BLE can carry identity — is the root cause. No amount of payload engineering fixes the fundamental unreliability of BLE as an identity transport.

## Decision

Redefine BLE as a **discovery-only wakeup hint**. BLE advertisements carry only the frozen Aethos service UUID (`181aa585-5a29-50f9-87f7-0e6cd20dee4e`). No identity, no metadata, no version flags. Identity is established exclusively through the post-connection Encounter handshake over a reliable transport.

The full V2 specification is in `docs/protocol/ble-identity-v2.md`.

## Consequences

### Positive

- **Portable**: UUID-only advertisement works identically on iOS, Android, and embedded platforms with no platform-specific workarounds.
- **Resilient**: Discovery cannot fail due to missing or corrupt identity bytes. If the UUID is visible, the hint is valid.
- **Simpler**: Advertisers emit a single AD structure. Scanners match on UUID only. No payload parsing, no version negotiation, no fail-closed identity checks at the BLE layer.
- **Privacy-safe by default**: No identity material is broadcast over the air. BLE address rotation becomes irrelevant to protocol correctness.

### Negative

- **No identity differentiation at BLE layer**: Scanners cannot distinguish between Aethos peers until the Encounter handshake completes. Multiple nearby peers produce identical wakeup hints.

### Mitigations

- **Bounded discovery windows**: Scanners activate a time-limited connection window on wakeup, preventing unbounded resource consumption from undifferentiated hints.
- **Debounce**: Duplicate wakeup hints from the same BLE address within a short window are coalesced, reducing unnecessary connection attempts.
- **Diagnostics**: Implementations SHOULD log wakeup-to-handshake latency and connection attempt counts to surface discovery performance regressions.
