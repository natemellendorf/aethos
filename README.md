<p align="center">
  <img src="docs/img/banner.jpg" alt="Aethos banner" width="960">
</p>

Aethos is a deterministic, store-and-forward data exchange protocol designed for unreliable, intermittent, or constrained links.

It provides a protocol specification and a reference implementation for exchanging authenticated data between peers without requiring stable connections, long-lived sessions, or trusted transports.

---

## What Problem Does Aethos Solve?

Most modern protocols assume:

- Stable connectivity
- Ordered, lossless transport
- Long-lived sessions
- Centralized coordination

Aethos assumes none of these.

It is designed for environments where:

- Connections are brief, unreliable, or opportunistic
- Data may be duplicated, delayed, or reordered
- Peers operate asynchronously
- Progress must be made incrementally, session by session

Aethos enables **eventual, verifiable delivery** under these conditions.

---

## Core Concepts

### Deterministic Protocol Objects

All protocol objects have stable, content-derived identifiers:

- Chunks
- Manifests
- Envelopes
- Receipts

This enables idempotency, deduplication, integrity verification, and replay tolerance by design.

---

### Explicit Protocol Layers

Aethos strictly separates concerns:

- Canonical encoding (Canonical Bytes)
- Identity and cryptography
- Chunking and manifests
- Routing and session planning
- Transport framing and links

No behavior is implicit in the transport layer.

---

### Sessionless Progress

Each exchange session:

- Operates under explicit budgets (bytes and items)
- Requires no shared session state
- Can be repeated safely

Repeated sessions converge naturally without coordination.

---

### Self-Certifying Identity

Every Aethos node has a **self-certifying identity**: the Wayfarer ID is derived deterministically from the node's public key.

- **Derivation**: `wayfarerId = SHA-256(Ed25519 signing public key)` (64-char hex)
- **Verification**: Any peer can verify a claimed Wayfarer ID by re-deriving it from the presented public key
- **Key type**: Ed25519 (Curve25519.Signing) for compact 32-byte keys and fast signatures
- **Exchange key**: Curve25519 key agreement (X25519) for sealed payload key delivery

This means:
- Identity cannot be spoofed without the corresponding private key
- No central authority is needed to assign or verify identities
- Peers can authenticate each other without prior coordination

**Storage layout** (under peer home `identity/` directory):
- `identity-v2.json` — metadata (key type, public keys hex, creation timestamp)
- `private.key` — raw private key bytes (0600 permissions)
- `public.key` — raw public key bytes
- `identity-v1.json` — backward-compatible key snapshot

**Identity rotation**: To rotate identity, delete the identity directory and re-run `aethos init`. This generates a new keypair and a new Wayfarer ID. Peers will see the new identity as a different node. A future bead will add explicit rotation with continuity proofs.

---

### Crypto-First Design

Security is part of the protocol itself:

- Ed25519 self-certifying identities
- Signed receipts
- Sealed key exchange (Curve25519)
- Authenticated payload encryption (ChaCha20-Poly1305)

There is no assumption of a secure transport.

---

## Repository Structure

AethosCore/
Sources/
Canonical/ Canonical encoding
Crypto/ Payload encryption and sealing
Identity/ Identity management and signing
Chunking/ Chunking and manifest logic
Routing/ Session planning and prioritization
Store/ SQLite-backed persistence
Transport/ Frames and link abstraction
Sim/ In-memory simulation
Tests/
docs/
protocol.md Protocol documentation


---

## Current Status

Aethos currently includes:

- Canonical encoding v1 with stable test vectors
- Deterministic identifiers for all protocol objects
- Chunking, manifests, and reassembly
- SQLite-backed durable store
- Routing and session planning
- Explicit transport framing
- End-to-end simulated delivery under constrained budgets

It is suitable as a **reference implementation and experimentation platform**.

---

## App Pivot Readiness

APP_PIVOT_READY: true

---

## Non-Goals

Aethos is **not** intended to be:

- A replacement for TCP or HTTP
- A real-time streaming protocol
- A low-latency RPC system

It prioritizes correctness, resilience, and eventual delivery over immediacy.

---

## License

Licensed under the Apache License, Version 2.0.  
See [LICENSE](LICENSE) for details.
