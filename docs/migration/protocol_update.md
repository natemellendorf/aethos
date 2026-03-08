# Protocol Migration Plan
## Canonical roadmap for Aethos protocol alignment and distributed message sync

## Status
Draft

## Owner
Aethos project

## Purpose
This document is the canonical step-by-step plan for completing the current Aethos protocol migration across repositories.

It exists to prevent loss of context as work spans multiple repos, multiple beads, and multiple implementation phases.

This document defines:
- the target architecture
- the migration phases
- the exact work required per repository
- compatibility expectations during transition
- sequencing and dependencies
- acceptance criteria for each phase
- open questions and future work

## See also

- [Legacy cleanup plan](./CLIENT_RELAY_LEGACY_CLEANUP_PLAN.md)
- [Client-relay conformance fixtures](./CLIENT_RELAY_CONFORMANCE_FIXTURES.md)
- [Compatibility matrix](./PROTOCOL_COMPATIBILITY_MATRIX.md)

---

# 1. Problem Statement

Aethos currently has protocol behavior and messaging semantics spread across multiple repositories.

In practice, `aethos-relay` has historically acted as the de facto source of truth for important protocol behavior, including:
- client relay messaging
- queued delivery
- TTL persistence
- per-device delivery tracking
- relay federation
- forwarding semantics
- hop count limits
- loop prevention

This is architecturally incorrect for the long-term direction of Aethos.

The `aethos` repository must become the canonical home for:
- protocol contracts
- receipt semantics
- message movement semantics
- future sync and gossip behavior

Relay and client repositories must become implementations of those contracts.

---

# 2. Desired End State

The target end state for this migration is:

## 2.1 Canonical protocol ownership
The `aethos` repository owns formal, versioned protocol specifications.

## 2.2 Clear implementation boundaries
- `aethos-relay` implements canonical specs and relay-specific runtime behavior
- `aethos-ios` implements canonical client behavior for iOS
- future clients do the same

## 2.3 Explicit receipt semantics
The system distinguishes between:
- device-level message receipt
- relay-level envelope receipt
- future peer-stored sync receipt
- future final-delivery receipt if introduced

These semantics must not be conflated.

## 2.4 Transport-neutral message sync
Aethos evolves from relay-centric queue delivery into a transport-neutral, store-and-forward sync model that supports:
- relay ↔ client
- relay ↔ relay
- client ↔ client on LAN
- eventually other intermittent or opportunistic transports

## 2.5 Relays are nodes, not the protocol
Relays remain important, but they become long-lived nodes with storage and routing behavior, not the place where the rules are defined.

---

# 3. Migration Principles

The following principles govern all work in this plan.

## 3.1 Preserve behavior before changing behavior
Refactors should first isolate and document behavior before attempting semantic changes.

## 3.2 Separate protocol from runtime heuristics
Protocol contracts belong in `aethos`.
Runtime heuristics belong in implementations.

Examples of protocol concerns:
- frame types
- field meanings
- TTL rules
- receipt semantics
- hop-count rules
- loop-prevention requirements

Examples of runtime concerns:
- scoring weights
- batching intervals
- retry timing
- peer exploration probability
- metrics endpoints

## 3.3 One semantic change at a time
Avoid bundling multiple behavior changes into one bead.

## 3.4 Backward compatibility during migration
When changing protocol behavior, preserve interop with existing clients and relays where feasible until coordinated cutover is complete.

## 3.5 Write down divergences before fixing them
If implementation behavior differs from spec, document it first. Then change it intentionally.

## 3.6 Every protocol rule should have a home
If a rule matters for interoperability, it must be written down in `aethos`.

---

# 4. Repositories and Responsibilities

## 4.1 aethos
Canonical home for:
- protocol specs
- receipt vocabulary
- ADRs for protocol decisions
- compatibility matrix
- migration tracking
- future transport-neutral sync contracts

## 4.2 aethos-relay
Responsible for:
- implementing canonical client-relay and federation protocols
- relay-specific persistence and operational behavior
- conformance documentation
- store-and-forward engine
- testing runtime behavior against canonical specs

## 4.3 aethos-ios
Responsible for:
- implementing canonical client-relay protocol
- documenting divergences during migration
- eventually implementing client sync behavior
- eventually implementing LAN discovery and direct peer sync

## 4.4 aethos-linux and future clients
Responsible for:
- implementing canonical protocol contracts
- reusing sync semantics
- supporting future LAN and opportunistic delivery

---

# 5. Migration Phases Overview

This migration is divided into seven phases.

## Phase 0
Foundation and protocol ownership

## Phase 1
Divergence audit

## Phase 2
Relay engine stabilization

## Phase 3
Protocol alignment

## Phase 4
Gossip sync implementation

## Phase 5
LAN discovery and local peer delivery

## Phase 6
Federation evolution and possible protocol unification

## Phase 7
Security and adversarial hardening

---

# 6. Phase 0 — Foundation and Protocol Ownership

## Objective
Move protocol authority into `aethos` and establish a shared language for the migration.

## Status
Partially complete / in progress

## Steps

### Step 0.1
Create canonical ADR in `aethos` declaring that protocol contracts are owned by `aethos`.

### Step 0.2
Create canonical `CLIENT_RELAY_PROTOCOL_V1.md` in `aethos`.

### Step 0.3
Create canonical `FEDERATION_PROTOCOL_V1.md` in `aethos`.

### Step 0.4
Create canonical `RECEIPTS.md` in `aethos`.

### Step 0.5
Finalize `GOSSIP_SYNC_V1.md` in `aethos` as the canonical v1 transport-neutral sync contract.

### Step 0.6
Update `aethos-relay` documentation to reference `aethos` as the canonical spec location.

### Step 0.7
Update `aethos-ios` documentation to reference canonical specs and record observed divergences.

## Exit Criteria
- `aethos` contains canonical protocol docs
- `aethos-relay` no longer presents itself as the source of truth
- `aethos-ios` links to canonical docs
- receipt terminology exists in one shared location

---

# 7. Phase 1 — Divergence Audit

## Objective
Document all meaningful differences between implementations and the canonical specs before making compatibility-breaking changes.

## Why this phase matters
Without a divergence audit, later changes become ambiguous. It becomes difficult to know whether a failure comes from:
- a bug
- an undocumented historical behavior
- a planned spec change
- an incomplete migration

## Step-by-step

### Step 1.1 — Create master compatibility matrix in aethos
Create:

`docs/migration/PROTOCOL_COMPATIBILITY_MATRIX.md`

This file should include a table with columns like:
- feature / field / semantic
- canonical spec
- aethos-relay current behavior
- aethos-ios current behavior
- status
- planned migration bead
- notes

### Step 1.2 — Create relay divergence document
Create in `aethos-relay`:

`docs/PROTOCOL_DIVERGENCES.md`

Document:
- client protocol field differences
- error frame differences
- timestamp differences
- encoding differences
- federation semantic differences
- ack behavior differences
- any undocumented operational assumptions

### Step 1.3 — Create iOS divergence document
Create in `aethos-ios`:

`docs/PROTOCOL_DIVERGENCES.md`

Document:
- hello frame differences
- missing fields such as `device_id`
- pull behavior assumptions
- error frame assumptions
- timestamp parsing assumptions
- encoding assumptions
- any client-side deviations from canonical semantics

### Step 1.4 — Record migration priority for each divergence
Each divergence must be classified as one of:
- documentation-only
- compatibility-safe
- requires coordinated rollout
- future work

### Step 1.5 — Add version / cutover notes
For each coordinated change, document:
- whether both old and new forms are accepted during transition
- which repo changes first
- what completes the cutover

## Exit Criteria
- all known divergences are written down
- compatibility matrix exists
- each divergence has a migration plan
- no important semantic gap remains “tribal knowledge”

---

# 8. Phase 2 — Relay Engine Stabilization

## Objective
Isolate the relay’s current store-and-forward behavior into a clear internal module without changing external behavior.

## Why this phase matters
The relay currently contains important implicit message movement logic. Before aligning semantics, that logic must become visible, modular, and testable.

## Step-by-step

### Step 2.1 — Complete internal store-and-forward engine extraction
In `aethos-relay`, extract a focused internal engine/module for:
- message persistence
- TTL checks
- queued delivery
- per-device delivery tracking
- federation envelope creation
- federation forwarding
- relay acknowledgment handling
- hop limit enforcement
- loop prevention
- expiry sweep integration

### Step 2.2 — Write internal engine note
Create:

`docs/internal/STORE_AND_FORWARD_ENGINE.md`

Document current behavior, not ideal future behavior.

### Step 2.3 — Separate semantic layers in code
Organize internal code around:
- message persistence
- delivery tracking
- federation forwarding
- receipt handling
- expiry and garbage collection

### Step 2.4 — Add behavior-pinning tests
Add tests for:
- send persists message with TTL
- pull returns queued messages
- one device ack does not suppress another device
- forwarded envelope preserves expiry
- hop count increments on forward
- hop limit enforcement
- loop prevention
- expired messages not returned
- expired envelopes dropped

### Step 2.5 — Clarify comments around receipt types
Add code comments that clearly distinguish:
- device-level ack
- relay-level envelope ack

## Exit Criteria
- relay behavior is modularized
- external behavior preserved
- tests pin current semantics
- relay is easier to evolve safely

---

# 9. Phase 3 — Protocol Alignment

## Objective
Bring implementations into alignment with the canonical specs, one divergence at a time.

## Important rule
Do not combine unrelated semantic changes into one bead.

## Migration order
Protocol alignment should proceed in a sequence that minimizes compatibility risk.

## Candidate sequence

### Step 3.1 — Introduce device_id in client hello
#### Goal
Move from wayfarer-only device identity to explicit `(wayfarer_id, device_id)` identity.

#### Work in aethos-ios
- generate stable device_id
- include device_id in hello frame
- persist device_id locally

#### Work in aethos-relay
- accept hello with device_id
- continue accepting hello without device_id during migration
- use device_id for per-device delivery tracking where present

#### Compatibility rule
Both old and new hello formats should be accepted during transition.

#### Exit criteria
- iOS sends device_id
- relay accepts and uses it
- compatibility matrix updated

---

### Step 3.2 — Normalize timestamp fields
#### Goal
Align timestamp field names and semantics.

Potential examples:
- `at`
- `received_at`
- `created_at`

#### Work
- document canonical meanings in `aethos`
- relay emits canonical fields or dual fields during migration
- iOS accepts both during migration
- remove legacy form only after all clients are updated

#### Exit criteria
- timestamps have unambiguous names
- both sides parse the same semantics
- no ambiguity remains in docs

---

### Step 3.3 — Normalize payload encoding
#### Goal
Align on canonical unpadded base64url encoding per `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md#1-transport-and-encoding`.

#### Work
- relay accepts legacy encoding and canonical encoding during transition
- iOS emits canonical encoding once safe
- docs updated with exact encoding rules

#### Exit criteria
- canonical encoding is used consistently
- transitional compatibility removed only after cutover

---

### Step 3.4 — Normalize error frame structure
#### Goal
Move from ad hoc error frames to structured error payloads.

#### Work
- define canonical error schema
- relay emits structured errors
- iOS supports old and new forms during transition
- logging updated to reflect structured errors

#### Exit criteria
- error frames are predictable and documented
- clients can display or log them reliably

---

### Step 3.5 — Align federation ack semantics
#### Goal
Ensure relay federation acknowledgments match canonical definitions exactly.

#### Work
- confirm ack statuses
- align names and meanings
- add tests for each ack status

#### Exit criteria
- federation ack meaning is precise and tested

---

# 10. Phase 4 — Gossip Sync Implementation

## Objective
Implement the protocol-level “send all messages I have” behavior as a transport-neutral sync model.

## Why this phase matters
This is the architectural flip from relay-centric queueing to distributed, opportunistic message delivery.

## Concept
When two nodes connect, they should be able to exchange:
- what messages they hold
- what messages the other side is missing
- the requested payloads
- receipts that prevent redundant re-sends

This must work for:
- relay ↔ client
- relay ↔ relay
- client ↔ client

## Step-by-step

### Step 4.1 — Finalize sync spec in aethos
If not already complete, finish `GOSSIP_SYNC_V1.md`.

Define:
- InventorySummary
- MissingRequest
- Transfer
- Receipt
- paging behavior
- idempotency rules
- sync budgets
- receipt semantics
- retry expectations

### Step 4.2 — Define sync runtime interfaces
In `aethos`, define interface expectations for:
- storage adapter
- transport adapter
- sync session manager

### Step 4.3 — Implement transport-neutral sync engine
Preferred location:
- `aethos` if acceptable for repo boundaries
or
- a shared runtime module if you choose to keep `aethos` spec-heavy

Responsibilities:
- manage sync session state
- compare inventory
- request missing items
- transfer payloads
- process sync receipts
- remain idempotent

### Step 4.4 — Add sync conformance tests
Test:
- inventory convergence
- duplicate suppression
- paged sync behavior
- repeated sync safety
- partial inventory overlap
- retry after disconnect

Canonical fixture references for this phase:
- `docs/migration/GOSSIP_SYNC_CONFORMANCE_FIXTURES.md`
- `testdata/gossip_sync/v1/*.json`

### Step 4.5 — Integrate sync with relay
In `aethos-relay`:
- integrate sync engine without breaking current queue behavior
- initially use sync in controlled paths if needed
- ensure current pull and queue semantics remain compatible during rollout

### Step 4.6 — Integrate sync with iOS
In `aethos-ios`:
- trigger sync on connection establishment
- maintain one sync session per peer
- store received payloads idempotently

## Exit Criteria
- Aethos supports transport-neutral sync
- repeated sessions converge safely
- held messages can propagate beyond simple relay queue pull

---

# 11. Phase 5 — LAN Discovery and Local Peer Delivery

## Objective
Enable local peers to discover one another automatically and perform sync without explicit user action.

## Why this phase matters
This phase delivers the local-network behavior you originally asked for.

## Key architecture decision
Discovery should live in client/runtime implementations, while the sync contract remains defined in `aethos`.

## Step-by-step

### Step 5.1 — Define discovery contract in aethos
Document:
- peer descriptor shape
- discovered endpoint semantics
- dedupe by peer identity
- expiry rules

### Step 5.2 — Implement iOS local discovery
Likely mechanism:
- mDNS / Bonjour
or
- multicast if needed

Advertise:
- wayfarer_id
- device_id
- reachable endpoint(s)
- optional capability hints

### Step 5.3 — Implement Linux local discovery
Support equivalent discovery for Linux clients.

### Step 5.4 — Build peer table abstraction
Clients maintain:
- discovered peer identities
- endpoints
- last seen
- expiry
- sync eligibility

### Step 5.5 — Trigger sync on discovery-driven connection
Flow:
- discover peer
- connect
- run gossip sync
- update held message inventory

### Step 5.6 — Add diagnostics UI and logs
In iOS:
- show discovered peers
- last seen time
- active sync state
- recent sync results

## Exit Criteria
- local peers are discovered automatically
- connection happens automatically or semi-automatically
- sync runs without manual message routing
- held messages propagate locally

---

# 12. Phase 6 — Federation Evolution

## Objective
Reduce duplication between relay federation logic and the broader sync model.

## Why this phase matters
Today relay federation has its own forwarding shape. Long term, you may want federation and gossip sync to share more machinery.

## Step-by-step

### Step 6.1 — Compare federation forward model to gossip sync model
Document overlap and differences.

### Step 6.2 — Decide whether federation remains distinct or converges
Possible outcomes:
- keep federation protocol distinct
- unify message transfer semantics
- unify receipt handling
- unify inventory exchange patterns

### Step 6.3 — Refactor relay if unification is chosen
Only after sync engine is stable.

### Step 6.4 — Add federation compatibility tests
Ensure multi-relay message propagation remains correct after any refactor.

## Exit Criteria
- federation and sync have a clear relationship
- duplicated semantics are reduced where practical
- relay behavior remains robust

---

# 13. Phase 7 — Security and Hardening

## Objective
Add protections against bad actors after semantics are stable.

## Important note
Security should not be bolted onto semantic ambiguity. It should be added after receipt meanings, sync behavior, and identity models are stable.

## Candidate future work
- signed envelopes
- signed advertisements
- relay authenticity
- spam controls
- abuse resistance
- trust establishment between peers
- proof or confidence model for final delivery
- anti-loop and anti-replay protections beyond current seen tracking

## Exit Criteria
Defined in future security roadmap.

---

# 14. Canonical Tracking Documents

The following documents should exist and be kept up to date.

## In aethos
- `docs/migration/protocol_update.md` (this canonical migration plan)
- `docs/migration/protocol_architecture.md`
- `docs/migration/PROTOCOL_COMPATIBILITY_MATRIX.md`
- `docs/migration/GOSSIP_SYNC_CONFORMANCE_FIXTURES.md`
- `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md`
- `docs/spec/FEDERATION_PROTOCOL_V1.md`
- `docs/spec/RECEIPTS.md`
- `docs/spec/GOSSIP_SYNC_V1.md`
- relevant ADRs

## In aethos-relay
- `docs/PROTOCOL_DIVERGENCES.md`
- `docs/PROTOCOL_CONFORMANCE.md`
- `docs/internal/STORE_AND_FORWARD_ENGINE.md`

## In aethos-ios
- `docs/PROTOCOL_REFERENCE.md`
- `docs/PROTOCOL_DIVERGENCES.md`

---

# 15. Bead Inventory by Repository

## aethos
1. create protocol ownership ADR
2. create canonical client relay spec
3. create canonical federation spec
4. create receipt vocabulary spec
5. create master compatibility matrix
6. create migration plan
7. finalize gossip sync spec
8. define sync runtime interfaces
9. implement or host shared sync engine
10. add sync conformance tests

## aethos-relay
1. documentation alignment to canonical specs
2. protocol divergence doc
3. store-and-forward engine extraction
4. engine behavior-pinning tests
5. device_id support
6. timestamp normalization support
7. encoding normalization support
8. error frame normalization support
9. federation ack alignment
10. sync engine integration
11. federation evolution work

## aethos-ios
1. protocol reference doc
2. protocol divergence doc
3. stable device_id generation
4. hello frame update
5. timestamp compatibility work
6. encoding compatibility work
7. error frame compatibility work
8. sync engine integration
9. LAN discovery implementation
10. diagnostics UI for discovery and sync

---

# 16. Migration Gates

The following gates should be used to decide whether a phase is complete.

## Gate A — Foundation complete
- canonical specs exist
- docs point to canonical source
- divergence tracking started

## Gate B — Divergence audit complete
- compatibility matrix exists
- relay divergences documented
- iOS divergences documented
- every known divergence has a planned migration path

## Gate C — Relay stabilization complete
- store-and-forward engine extracted
- behavior-pinning tests exist
- no external behavior changed accidentally

## Gate D — Core protocol alignment complete
- device_id cutover complete
- timestamps aligned
- encoding aligned
- error schema aligned
- federation ack semantics aligned

## Gate E — Sync complete
- transport-neutral sync implemented
- repeated sessions converge safely
- held messages sync correctly

## Gate F — LAN delivery complete
- peer discovery works
- sync is triggered on local peer connection
- local propagation works without explicit routing by user

---

# 17. Open Questions

The following questions should be answered during the migration.

## Q1
Should `aethos` host executable shared sync code, or should that live in a new shared runtime module?

## Q2
Rollout verification question (decision already recorded):
Confirm all clients and relays have cut over to canonical unpadded base64url payload encoding and remove legacy base64 acceptance.

## Q3
What is the exact canonical timestamp vocabulary?
For example:
- created_at
- received_at
- accepted_at
- delivered_at

## Q4
What is the final shape of the client hello frame?
Must `device_id` be required immediately, or optional during transition?

## Q5
Will federation remain a distinct protocol layer long term, or eventually converge on shared sync transfer primitives?

## Q6
What constitutes “final delivery” in the future security model?
Is device ack enough?
Is peer-stored enough?
Is a signed final-recipient receipt required?

---

# 18. Immediate Next Actions

The next concrete actions should be:

## Migration update (2026-03-08)

Client-relay legacy cleanup verification is now far enough along to start the next phase of protocol work: **transport-neutral gossip sync implementation plus LAN discovery integration**.

- Relay-side canonical-only cleanup is largely complete for client-relay wire behavior.
- iOS has canonical fixture coverage in place, with remaining runtime compatibility tolerances tracked as residual exceptions.
- The canonical migration scoreboard and residual exceptions are maintained in `docs/migration/PROTOCOL_COMPATIBILITY_MATRIX.md` under **Client-Relay Cutover Readiness (2026-03-08)**.

## Action 1
Keep this migration plan current in `docs/migration/protocol_update.md`.

## Action 2
Create or update `docs/migration/PROTOCOL_COMPATIBILITY_MATRIX.md`.

## Action 3
Ensure `aethos-relay/docs/PROTOCOL_DIVERGENCES.md` exists.

## Action 4
Ensure `aethos-ios/docs/PROTOCOL_DIVERGENCES.md` exists and includes the already observed notes:
- missing device_id in hello
- field-name differences such as at vs received_at
- error shape differences
- canonical base64url (no padding) vs legacy base64 compatibility expectations

## Action 5
Complete the relay store-and-forward engine extraction bead currently in progress.

## Action 6
Plan the first protocol alignment bead:
device_id introduction across relay and iOS with compatibility support.

---

# 19. Summary

This migration is not merely a documentation cleanup.

It is the transition from:
- relay-defined behavior
to
- protocol-defined behavior

and from:
- relay-centric queued messaging
to
- transport-neutral distributed store-and-forward messaging

That is the heart of the Aethos design goal:
nodes should not merely send messages they authored.
They should be able to carry, hold, and forward messages for others until delivery has a chance to occur.

This document exists to keep that arc visible from beginning to end.
