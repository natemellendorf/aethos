# RECEIPTS

Status: Canonical v1 receipt semantics

This document defines receipt vocabulary and transport semantics without changing the core `ReceiptV1` structure.

- Core receipt structure (normative): `docs/protocol.md` (`ReceiptV1`)
- Client-relay delivery semantics: `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md`
- Federation forwarding semantics: `docs/spec/FEDERATION_PROTOCOL_V1.md`

## 1. `ReceiptV1` Is Unchanged

`ReceiptV1` fields remain exactly as defined in `docs/protocol.md`:

1. `envelopeId`
2. `manifestId`
3. `receivedAtUnixMs`
4. `signature` (optional)

This spec does not add or remove `ReceiptV1` fields.

Timestamp unit for `receivedAtUnixMs` is fixed: Unix epoch milliseconds encoded as `UInt64`.

## 2. Vocabulary Layer

### DeviceReceipt

A `DeviceReceipt` is a `ReceiptV1` with semantics:

- delivery acknowledgment by a client device
- indicates device-level processing for that message

### FederationReceipt

A `FederationReceipt` is a `ReceiptV1` with semantics:

- envelope acceptance acknowledgment by another relay
- indicates relay-hop acceptance, not end-device delivery

## 3. Non-Conflation Requirement

`DeviceReceipt` and `FederationReceipt` are distinct and MUST NOT be conflated.

- A `FederationReceipt` MUST NOT be interpreted as recipient device delivery.
- A `DeviceReceipt` MUST NOT be interpreted as relay-federation acceptance.

## 4. Scope Signaling Without Modifying `ReceiptV1`

Because `ReceiptV1` has no built-in scope/kind discriminator:

- If a transport/channel can carry both `DeviceReceipt` and `FederationReceipt`, wrappers MUST carry explicit scope.
- If a transport/channel carries only one receipt scope by construction, scope MAY be implicit.

### 4.1 JSON transport wrapper (normative for JSON channels)

```json
{
  "receipt_scope": "device",
  "receipt_v1_b64": "o2..."
}
```

Fields:

- `receipt_scope`: string, `device` or `federation`
- `receipt_v1_b64`: base64url (no padding) canonical `ReceiptV1` bytes from `docs/protocol.md` (`Canonical Bytes v1`)

### 4.2 CBOR transport wrapper (logical equivalent)

When CBOR is used and explicit scope signaling is required, wrappers MUST carry equivalent semantics:

- `receipt_scope`: text (`"device"` or `"federation"`)
- `receipt_v1`: bytes (canonical `ReceiptV1`)

The wrapper is transport metadata only. The inner receipt remains `ReceiptV1`.
