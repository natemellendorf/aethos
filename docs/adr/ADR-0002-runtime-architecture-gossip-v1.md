# ADR-0002: Canonical Runtime Architecture for Gossip V1 Object Reconciliation

- Status: Proposed
- Date: 2026-03-14

## Context

Aethos Gossip V1 is often approached with a relay-RPC mental model:

- “Send message to relay”
- “Pull messages from relay”
- “Ack so the relay stops sending”

That model does not match Gossip V1 semantics. Gossip V1 is an object reconciliation system driven by encounters and durable object identity:

- local object composition and persistence
- encounter-driven inventory reconciliation
- transfer/receipt by `item_id`
- projection of stored objects into application views

Without a canonical runtime architecture, implementations risk conflating transport mechanics with reconciliation policy, and risk treating relays as special protocol authorities rather than ordinary gossip participants with different durability/policy settings.

## Decision

Gossip V1 implementations MUST use an object-reconciliation runtime model, not a relay-RPC model.

The canonical data model is:

1. Compose immutable objects.
2. Persist objects in a content-addressed object store.
3. Reconcile inventories during encounters.
4. Transfer missing objects by `item_id`.
5. Project local objects into product-facing views.

The relay-RPC framing (“send/pull/ack queue semantics”) is explicitly rejected for Gossip V1.

### Canonical Components

#### 1) Composer

Responsibilities:

- Build canonical envelope bytes.
- Compute deterministic `item_id` from immutable envelope bytes.
- Hand off immutable object records to storage.

Non-responsibilities:

- No network transport.
- No encounter scheduling.
- No remote delivery guarantees.

#### 2) Object Store

Responsibilities:

- Durable storage for objects keyed by `item_id`.
- Idempotent put/get and deduplication.
- Inventory enumeration for reconciliation and projection.

Non-responsibilities:

- No transport framing.
- No peer-selection logic.

#### 3) Encounter Engine

Responsibilities:

- Execute Gossip V1 encounter state machine.
- Reconcile local/peer inventory using protocol frames.
- Drive request/transfer/receipt exchange by `item_id`.

Non-responsibilities:

- No application-level rendering.
- No storage encoding policy beyond protocol invariants.

#### 4) Transport Adapter

Responsibilities:

- Convert transport I/O into valid Gossip V1 frame streams/datagrams.
- Enforce transport-level framing and bounds.
- Deliver inbound frames to Encounter Engine and outbound frames to network.

Non-responsibilities:

- No reconciliation policy.
- No object eligibility/scoring decisions.

#### 5) Projection Layer

Responsibilities:

- Derive read models from locally stored objects.
- Support application queries/views independent of transport session timing.

Non-responsibilities:

- No encounter orchestration.
- No wire protocol decisions.

#### Optional: Policy Layer

An implementation MAY add a policy layer for preference and scheduling only (for example: peer ranking, item prioritization, time/budget shaping).

Policy MUST NOT redefine wire semantics, object identity, or reconciliation correctness.

## End-to-End Data Flow

```text
Outbound (local creation to peer convergence)

  App Intent
      |
      v
  [Composer] --canonical envelope--> [Object Store]
                                         |
                                         v
                              [Encounter Engine]
                                         |
                                         v
                               [Transport Adapter] ---> Network/Peer

Inbound (peer data to local visibility)

  Network/Peer ---> [Transport Adapter] ---> [Encounter Engine] ---> [Object Store] ---> [Projection Layer] ---> App Views
```

Outbound explanation:

- Objects are created once, persisted once, then offered opportunistically during encounters.
- Transfer is by missing `item_id`; completion is convergent and repeat-safe.

Inbound explanation:

- Received objects are validated and persisted by identity.
- Projections update local views from store state, not from transport callbacks.

## Client and Relay Symmetry

Protocol roles are symmetric: both clients and relays participate in the same reconciliation loop (`SUMMARY`/`REQUEST`/`TRANSFER`/`RECEIPT`) over the same object identity rules.

Relays differ operationally (durability profile, admission/prioritization policy, uptime), not semantically. They are not authoritative queue owners in Gossip V1.

## Consequences

- Clear separation between reconciliation semantics and transport mechanics.
- Deterministic, idempotent convergence across heterogeneous runtimes.
- Easier portability: iOS, Linux, and relay implementations share one mental model.
- Tradeoff: teams must avoid convenient but incorrect queue/RPC abstractions.
- Risk: projection and policy concerns may leak into encounter or transport layers if boundaries are not enforced.

## Implementation Guidance

- Keep transport strictly below the Encounter Engine.
- Make Object Store the source of truth for both outbound eligibility and inbound materialization.
- Drive UI/app behavior from projections over stored objects, not from transient transport events.
- Preserve the same component boundaries for iOS, Linux, and relay runtimes even when packaged differently.
- Treat policy as pluggable preference/scheduling logic; keep it non-normative.

## Non-goals

- Defining relay product APIs or operational SLAs.
- Replacing encounter reconciliation with command/RPC semantics.
- Defining UI presentation logic.
- Introducing new wire-level protocol behavior.

## Glossary

- **Object reconciliation**: convergence process where peers discover and exchange missing objects by identity.
- **Encounter**: bounded peer interaction that runs Gossip V1 frame exchange.
- **Object Store**: local durable content-addressed inventory keyed by `item_id`.
- **Projection**: derived application view materialized from stored objects.
- **Policy layer**: optional selection/scheduling preferences that do not alter protocol correctness.
