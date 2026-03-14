<p align="center">
  <img src="docs/img/banner.jpg" alt="Aethos banner" width="960">
</p>

# Aethos Gossip Protocol (Gossip V1)

## Aethos in 10 Seconds

Aethos is a deterministic, store-carry-forward gossip protocol for moving messages across unreliable, intermittent, or constrained networks.

Instead of depending on a single server or a single delivery path, Aethos turns messages into portable protocol objects that can be stored, carried, replicated, and forwarded across encounters until they eventually reach their destination.

If a network path exists later, Aethos can use it.

If a node disappears, other replicas can continue carrying the message.

If connectivity is fragmented, progress can still happen.

## Visual Propagation Model

```text
User A
  │
  │ creates message object
  ▼
[A's local object store]
  │
  │ encounter
  ▼
User B
  │
  │ carries object while offline
  ▼
[Relay]
  │
  │ relay-to-relay gossip
  ▼
[Other Relay]
  │
  │ encounter / sync
  ▼
User Z

Messages are stored, carried, replicated, and forwarded until they reach their destination.
```

## What Aethos Is

Aethos is a transport-neutral gossip protocol designed for environments where connectivity may be:

- intermittent
- delayed
- fragmented
- unreliable
- constrained

It is built around deterministic protocol objects, encounter-driven synchronization, and multi-path replication.

The protocol does not assume that a sender and recipient are simultaneously online.

It does not assume that one server or one route is always available.

It does not assume that delivery must occur immediately.

Instead, Aethos assumes that information can move gradually through a network as nodes encounter one another.

## How Aethos Moves Messages

Most messaging systems think in terms of servers delivering messages.

Aethos thinks in terms of objects moving through a network.

When a message is created in Aethos, it becomes a content-addressed protocol object identified by a deterministic `item_id`.

That object is stored locally and then propagated through encounters.

Propagation is not tied to a single server or a single route. Instead:

1. a message becomes a locally stored object
2. when a node encounters another node or relay, they exchange inventory summaries
3. missing objects are requested
4. objects transfer and are verified
5. receipts acknowledge successful import

Over time, objects replicate across multiple nodes.

Eventually the destination peer receives the object and imports it.

This is a store-carry-forward model.

A node may:

- store the message
- carry it while disconnected
- forward it later when another peer appears

No single path is required for delivery.

The network behaves more like wind carrying a feather than a courier delivering a package.

Messages drift across the network until they reach their destination.

## Core Design Goals

- Deterministic, content-addressed objects and idempotent convergence
- Transport-neutral frames with bearer-specific boundaries
- Sessionless progress under explicit item/byte budgets
- Fail-closed validation for malformed, oversize, expired, or incompatible inputs
- Strict separation between wire correctness and local policy
- Resilient multi-path propagation across unreliable networks

## Protocol Documentation

The authoritative Gossip V1 specification lives in `docs/protocol/`.

Key documents:

- `docs/protocol/frames.md`
- `docs/protocol/gossip.md`
- `docs/protocol/encounter.md`
- `docs/protocol/replication.md`
- `docs/protocol/scoring.md`

Additional references:

- Architecture decisions: `docs/adr/`
- Interoperability fixtures: `Fixtures/Protocol/gossip-v1/`
- Core canonical object encoding: `docs/protocol.md`
- ADR-0002 runtime reconciliation architecture: `docs/adr/ADR-0002-runtime-architecture-gossip-v1.md`
- Protocol engine reference implementation: `AethosCore/Sources/AethosCore/Protocol/GossipV1/*`
- Transport stream adapter reference implementation: `AethosCore/Sources/AethosCore/Transport/GossipV1/*`

## Design Philosophy

Aethos was designed around a simple idea:

Communication should not depend on a single server, a single route, or a single point of failure.

Messages should be able to move through a network the way information spreads naturally.

When a message is created in Aethos, it becomes part of the network.

Nodes carry it.

Encounters move it forward.

Eventually it finds its destination.

The guiding philosophy can be summarized like this:

- messages should be free to move
- networks should be resilient by default
- delivery should not depend on centralized infrastructure
- the system should remain functional even when parts of the network disappear

Aethos aims to make communication feel unstoppable.

Unbound.

Like a feather floating on the wind.

No single node controls a message’s path.

The network itself carries it.
