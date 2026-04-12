# BLE Discovery Identity Contract v2 — Discovery-Only Wakeup Hint

Status: authoritative BLE discovery identity wire contract.

Supersedes: `docs/protocol/ble-identity-v1.md` (BLE Discovery Identity Contract v1).

## 1. Normative language and authority

The key words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** are to be interpreted as in RFC 2119.

Per `docs/adr/ADR-BLE-IDENTITY-V2.md`, BLE is redefined as a discovery-only wakeup hint. This document is canonical for BLE discovery behavior from V2 onward.

This contract defines only BLE discovery advertisement structure. It does **not** define identity exchange, capability negotiation, or any post-connection behavior. Those responsibilities belong to the Encounter handshake protocol (`docs/protocol/encounter.md`).

## 2. Purpose

BLE advertisement in Aethos V2 serves exactly one purpose: **notify nearby devices that an Aethos peer is present and available for connection**. This is a wakeup hint, not an identity assertion.

The advertisement carries no identity, no metadata, and no version information. A scanner that observes the Aethos service UUID knows only that *some* Aethos peer is nearby. Peer identity, capabilities, and protocol version are established exclusively through the post-connection Encounter handshake over a reliable transport.

## 3. Frozen constants

### 3.1 Primary service UUID

- Primary Aethos Discovery Service UUID (128-bit):
  - `181aa585-5a29-50f9-87f7-0e6cd20dee4e`
- Derivation (frozen, unchanged from V1): UUIDv5 (RFC 4122) with DNS namespace `6ba7b810-9dad-11d1-80b4-00c04fd430c8` and name `"aethos.ble.discovery.identity.v1"`.
- The derivation name retains `v1` because the UUID is frozen and MUST NOT change across protocol versions.

## 4. Required advertisement

### 4.1 Advertisement content

An Aethos V2 advertiser **MUST** include the primary service UUID in one of:

- AD type `0x07` (Complete List of 128-bit Service UUIDs), or
- AD type `0x06` (Incomplete List of 128-bit Service UUIDs)

in the primary advertisement PDU.

UUID bytes on air are little-endian BLE order:

- `4e ee 0d d2 6c 0e f7 87 f9 50 29 5a 85 a5 1a 18`

Example AD structure (single UUID, hex):

`11 07 4e ee 0d d2 6c 0e f7 87 f9 50 29 5a 85 a5 1a 18`

### 4.2 No additional payload

An Aethos V2 advertiser **MUST NOT** include AD type `0x21` (Service Data) keyed by the Aethos UUID. No identity payload, version byte, flags, capabilities, or any other Aethos-specific data is carried in the BLE advertisement.

Implementations **MAY** include non-Aethos AD structures (local name, TX power, manufacturer data for other services) provided they do not conflict with the Aethos UUID-list entry.

## 5. Optional fields

None. V2 defines no optional advertisement fields. The advertisement is exactly the UUID-list entry and nothing else.

Future protocol versions that require additional BLE-layer signaling MUST define a new ADR and specification. They MUST NOT extend V2 advertisements with additional Aethos-keyed AD structures.

## 6. Scanner acceptance rules

### 6.1 UUID-only matching

A conforming V2 scanner **MUST** accept a BLE advertisement as an Aethos wakeup hint if and only if:

1. The primary advertisement or scan response contains AD type `0x06` or `0x07` whose UUID list includes the exact Aethos primary service UUID.
2. For AD type `0x06`/`0x07`, `(Length - 1) % 16 == 0` (valid UUID-list structure).

If the UUID is present and the list structure is valid, the advertisement is accepted. No further payload inspection is required or permitted for V2 acceptance.

### 6.2 Overflow advertisement handling

On platforms where the OS moves service UUIDs to overflow areas (notably iOS), scanners **MUST** also check platform-specific overflow/solicitation structures for the Aethos UUID. If the UUID is found in an overflow area, the advertisement **MUST** be accepted as a valid wakeup hint.

### 6.3 AD type `0x21` presence

If an Aethos-keyed AD type `0x21` is present alongside the UUID-list entry, the scanner **MUST** ignore it for V2 acceptance purposes. The presence of service data does not invalidate the wakeup hint and does not trigger V1 parsing behavior. This ensures forward compatibility during the V1-to-V2 migration window where some peers may still emit V1 payloads.

### 6.4 Rejection

A scanner **MUST** reject (not treat as Aethos wakeup hint) any advertisement that does not contain the Aethos UUID in a valid UUID-list AD structure (including platform-specific overflow areas).

## 7. Wakeup semantics

### 7.1 Definition

A **wakeup hint** is a signal that an Aethos peer is likely nearby and available for connection. It carries no identity, no capability information, and no guarantee that a connection will succeed.

### 7.2 Scanner behavior on wakeup

Upon receiving a valid wakeup hint, a scanner **SHOULD**:

1. Activate the discovery window (Section 8).
2. Attempt connection to the advertising peer via the appropriate transport.
3. Perform the Encounter handshake to establish identity and capabilities.

A scanner **MUST NOT** infer any identity, capability, or protocol version from the wakeup hint alone.

### 7.3 Debounce

Scanners **SHOULD** coalesce duplicate wakeup hints from the same BLE address within a rolling window. The recommended debounce interval is 30 seconds. Implementations **MAY** adjust this interval based on platform constraints, but it **MUST NOT** exceed 120 seconds.

## 8. Discovery activation window

### 8.1 Purpose

The discovery activation window bounds the time a scanner spends attempting connections after a wakeup hint. This prevents unbounded resource consumption when multiple undifferentiated peers are nearby.

### 8.2 Timing

Upon receiving a wakeup hint (after debounce), the scanner **SHOULD** open a discovery activation window of 10 to 60 seconds. During this window, the scanner **MAY** attempt connections to the hinting peer.

After the window expires, the scanner **MUST** stop connection attempts for that BLE address until a new wakeup hint is received (subject to debounce).

### 8.3 Concurrent windows

Scanners **SHOULD** limit the number of concurrent discovery activation windows. The recommended maximum is 4 concurrent windows. Implementations **MAY** adjust this limit based on platform resources.

## 9. Identity rules

### 9.1 BLE carries no identity

BLE advertisement in V2 carries **no** identity information. The Aethos UUID identifies the *protocol*, not the *peer*.

### 9.2 Identity establishment

Peer identity **MUST** be established exclusively through the post-connection Encounter handshake. No implementation may treat BLE address, advertisement timing, signal strength, or any other BLE-layer observable as a proxy for peer identity.

### 9.3 BLE address instability

BLE peripheral addresses rotate unpredictably across platforms. Implementations **MUST NOT** assume BLE address stability for any purpose including deduplication, peer tracking, or connection caching.

## 10. Privacy

### 10.1 No identity broadcast

V2 broadcasts no identity material over the air. The only Aethos-specific content is the frozen service UUID, which identifies the protocol, not the peer.

### 10.2 BLE address rotation

BLE address rotation is a platform responsibility. V2 correctness does not depend on address rotation behavior. Implementations **SHOULD NOT** attempt to control or predict BLE address rotation.

### 10.3 Passive observer resistance

A passive observer can determine that an Aethos peer is nearby (by observing the UUID) but cannot distinguish between peers, link observations across address rotations, or extract any identity or capability information from the advertisement alone.

## 11. Security

### 11.1 No authentication at BLE layer

V2 includes no authentication, signing, or encryption at the BLE advertisement layer. The wakeup hint is inherently unauthenticated.

### 11.2 Spoofing

Any device can emit the Aethos UUID. Scanners **MUST** treat wakeup hints as untrusted. Authentication occurs exclusively in the Encounter handshake.

### 11.3 Denial of service

An adversary can generate spurious wakeup hints to trigger connection attempts. The discovery activation window (Section 8) and debounce (Section 7.3) bound the resource cost of such attacks. Implementations **SHOULD** monitor and log anomalous wakeup rates for operational diagnostics.

## 12. Interoperability

### 12.1 Cross-platform

V2 advertisement (UUID-list only) is supported identically on iOS (CoreBluetooth), Android (android.bluetooth.le), and embedded BLE stacks. No platform-specific payload encoding is required.

### 12.2 Coexistence with non-Aethos services

The Aethos UUID-list entry coexists with other service UUIDs, manufacturer data, and local name AD structures. Implementations **MUST NOT** require exclusive advertisement space.

### 12.3 Extended advertising

On platforms supporting BLE 5.0+ extended advertising, the same UUID-list AD structure **MAY** be placed in extended advertisement PDUs. No additional structures are required.

## 13. Migration from V1

### 13.1 Deprecation

BLE Identity V1 (`docs/protocol/ble-identity-v1.md`) is deprecated. New implementations **MUST** implement V2 only.

### 13.2 Transition period

During the transition period, existing V1 advertisers may continue emitting AD type `0x21` with identity payloads. V2 scanners **MUST** ignore Aethos-keyed AD type `0x21` service data (Section 6.3) and treat any advertisement containing the Aethos UUID in a valid UUID-list as a wakeup hint.

### 13.3 V1 scanner compatibility

V1 scanners will continue to find the Aethos UUID in the UUID-list and may attempt V1 parsing. When no AD type `0x21` is present, a strict V1 scanner will reject. This is expected and acceptable: V1 scanners will be updated to V2 as part of the migration.

### 13.4 End of transition

The transition period ends when all deployed implementations have been updated to V2. After the transition, implementations **SHOULD** stop emitting AD type `0x21` entirely.

## 14. Normative summary

A conforming V2 implementation **MUST**:

1. **Advertisers**: include the Aethos primary service UUID in AD type `0x07` or `0x06` in the primary advertisement.
2. **Advertisers**: NOT include Aethos-keyed AD type `0x21` service data (after transition period).
3. **Scanners**: accept any advertisement containing the Aethos UUID in a valid UUID-list (or platform overflow area) as a wakeup hint.
4. **Scanners**: ignore Aethos-keyed AD type `0x21` if present.
5. **Scanners**: NOT infer identity, capability, or version from the BLE advertisement.
6. **Scanners**: establish identity exclusively through the post-connection Encounter handshake.
7. **Scanners**: implement debounce and bounded discovery activation windows.
8. **All**: treat BLE addresses as unstable and non-identifying.
