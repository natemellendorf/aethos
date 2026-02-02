# Aethos

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

### Crypto-First Design

Security is part of the protocol itself:

- Ed25519 identities
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
