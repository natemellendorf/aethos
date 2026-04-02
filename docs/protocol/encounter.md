# Encounter Lifecycle and Deterministic Session Semantics

Status: authoritative encounter behavior for transport-neutral multi-bearer gossip.

## 1. Normative language

RFC 2119 terms are normative in this document.

## 2. Deterministic encounter model

An encounter is a temporary peer session over any bearer. Session semantics MUST be identical across LAN, relay, and future bearers.

In multi-bearer operation, each encounter instance is bearer-scoped. Bearer selection, switching, and retry sequencing are local orchestration decisions and MUST NOT change frame semantics, frame types, or envelope schema.

Session objectives:

1. establish version/identity compatibility,
2. exchange deterministic inventory summary,
3. request and transfer missing objects within fixed budgets,
4. converge idempotently across repeated encounters.

## 2.1 Multi-bearer encounter scoping (normative)

1. A single encounter instance MUST execute on exactly one bearer.
2. Moving work to a different bearer MUST be modeled as ending the current encounter instance and starting a new encounter instance.
3. Local schedulers MAY run multiple opportunities over time (or in parallel) across bearers, but each opportunity MUST independently satisfy this encounter contract.
4. Bearer switching decisions are local-only and MUST NOT require new wire fields or frame variants.

## 2.2 Local lifecycle entities (normative)

Encounter lifecycle modeling uses three local-only entities with distinct scope:

1. `EncounterContext` (durable): long-lived orchestration state for a peer/contact across multiple encounter instances; owns policy memory, transition intent, and resume markers.
2. `Encounter` instance (bearer-scoped): one bounded encounter on exactly one bearer opportunity.
3. `EncounterAttempt` (execution-scoped): one concrete runtime attempt inside one encounter instance (for example: connect -> HELLO -> SUMMARY/REQUEST/TRANSFER loop -> close/fail).

Invariants:

1. `EncounterContext` MAY create multiple encounter instances over time.
2. An encounter instance MUST remain on one bearer for its lifetime.
3. If local orchestration chooses a different bearer, it MUST terminate the current encounter instance and create a new encounter instance.
4. Every `EncounterAttempt` MUST terminate in exactly one of: `clean-end`, `failed-end`, or `policy-stop`.
   Clarification: the terminal outcome tokens are `clean-end|failed-end|policy-stop`. The attempt state machine uses terminal states that correspond 1:1 with these outcomes.
5. Interruption markers MAY be emitted in addition to attempt termination outcomes; `EncounterContext` uses those markers to plan subsequent encounter instances.

## 3. HELLO and identity derivation

Source attribution note: see `docs/protocol/gossip.md` §2.1 for active-contract precedence across protocol/spec/ADR documents.

HELLO fields are defined in `docs/protocol/frames.md`.

Identity rules:

1. `node_id` MUST equal lowercase hex `SHA-256(node_pubkey_raw_bytes)`.
2. Node identity SHOULD persist across restarts while key material is unchanged.
3. If identity rotates (new key), peer MUST treat rotated identity as a new node.
4. HELLO metadata MUST NOT be used as sole trust decision input.
5. HELLO identity is session/peer identity only and MUST NOT override canonical envelope author attribution.

Envelope author attribution boundary (normative):

1. Gossip envelope author identity **MUST** be derived only from `author_pubkey` as `wayfarer_id = SHA-256(author_pubkey)`.
2. Transport/session metadata and HELLO identity are peer/session context only.
3. Peer/session identifiers **MUST NOT** be displayed or persisted as envelope author identity.

## 4. Version mismatch behavior (fail-closed)

1. If `HELLO.version != GOSSIP_VERSION`, encounter MUST fail closed.
2. On mismatch, node MUST stop frame processing for that session.
3. Session termination SHOULD be graceful (close stream / end datagram exchange cleanly).

## 5. Session framing expectations

1. Frame envelope and boundaries MUST follow `docs/protocol/frames.md`.
2. RFC 8949 deterministic CBOR encoding MUST be used for all frames.
3. For stream bearers, decoder MUST process exactly one length-prefixed frame at a time.
4. For datagram bearers, partial frames MUST be rejected.
5. Bearer re-ordering or duplication MUST be handled through idempotent `item_id` processing.

## 6. SUMMARY cadence guidance

1. Node MUST send SUMMARY at session start after HELLO success.
2. Node SHOULD send a refreshed SUMMARY after significant inventory change during long encounters.
3. Node SHOULD send SUMMARY after completing a large transfer batch.
4. Later encounters MUST continue convergence idempotently.

## 6.1 Bloom filter determinism (mandatory)

For identical object sets, compliant implementations MUST produce identical `SUMMARY.bloom_filter` bytes.

Deterministic mapping rules:

1. Hash primitive MUST be SHA-256.
2. For each `item_id` (64-char lowercase hex), derive `item_bytes` by hex-decoding.
3. For hash index `i` in `[0, BLOOM_HASH_COUNT-1]`, compute `digest_i = SHA-256(item_bytes || uint8(i))`.
4. Interpret first 8 bytes of `digest_i` as unsigned 64-bit big-endian integer `v_i`.
5. Compute `bit_index = v_i mod (BLOOM_FILTER_BYTES * 8)`.
6. Compute `byte_index = bit_index // 8`.
7. Compute `bit_offset = bit_index % 8` using LSB0 ordering (bit 0 is least-significant bit).
8. Set `bloom_filter[byte_index] |= (1 << bit_offset)`.

Initial Bloom buffer MUST be all zero bytes.

## 6.2 Deterministic SUMMARY preview membership selection (normative)

If a sender includes `SUMMARY.preview_item_ids`, it MUST select membership deterministically before applying on-wire ordering constraints from `docs/protocol/frames.md`.

Definitions:

- `W`: sender-chosen preview window size where `0 <= W <= MAX_SUMMARY_PREVIEW_ITEMS`.
- `eligibleItemIDs`: sender-local eligible item IDs at SUMMARY emission time. This exact set MUST be the set used for both `SUMMARY.item_count` and `SUMMARY.bloom_filter` construction.
- `previewCandidates`: sender-local eligible objects for preview at SUMMARY emission time; this set MUST be derived from the same eligibility snapshot as `eligibleItemIDs`.
- `decodedDigestBytes(item_id)`: hex-decode the 64-character lowercase-hex `item_id` into 32 bytes.
- `bytewise lexicographic order`: compare byte arrays left-to-right using each byte as an unsigned value in `[0, 255]`.

Rules:

1. Rank `previewCandidates` by this ascending tuple:
   1. earliest `expiry_unix_ms` first (equivalently, lowest remaining TTL at emission time),
   2. then lowest `hop_count`,
   3. then bytewise lexicographic order of `decodedDigestBytes(item_id)`.
2. Select up to `W` IDs as `selectedPreviewIDs` using a deterministic membership policy that preserves urgent-first behavior under the ranking from Step 1:
   1. choose the first `U` IDs from the head of the ranked list (`0 <= U <= W`),
   2. if capacity remains, fill `W - U` slots from the remaining ranked candidates using a deterministic local policy.
3. To satisfy `frames.md` wire requirements, `SUMMARY.preview_item_ids` MUST be the IDs from `selectedPreviewIDs` re-sorted by bytewise lexicographic order of `decodedDigestBytes(item_id)` (ascending).
4. `SUMMARY.preview_cursor` derivation happens after Step 3 (post-selection wire ordering): if `SUMMARY.preview_item_ids` is non-empty, `SUMMARY.preview_cursor = last(SUMMARY.preview_item_ids)`; if empty, `SUMMARY.preview_cursor` MUST be absent.
5. Therefore, prioritization is represented by membership selection only, not by on-wire array order.

Determinism requirements:

1. For a given emission-time snapshot, selection MUST be a pure function of that snapshot (plus persisted local state, if such state is part of the deterministic policy) and MUST be stable across runs and restarts.
2. Tie-break comparison MUST use canonical bytewise comparison of `decodedDigestBytes(item_id)` (not hex-string ordering).
3. Implementations MUST NOT use randomness, hash-map iteration order, or other non-deterministic iteration as ranking input.

Fairness note (non-normative local policy):

- Implementations MAY apply deterministic rotation/mixing to reduce starvation of long-lived items.
- One deterministic strategy is: always include `U = min(W, urgent_budget)` urgent IDs from the ranked head, then fill `W-U` from remaining eligible IDs in canonical `item_id` byte order using a persisted local-only rotation offset/seed.
- Any such policy should preserve urgent-first behavior from the ranking in Step 1 and should be independent of on-wire `SUMMARY.preview_cursor`.

Example (1000 backlog / 32 preview):

Implementation note: this example uses `W = 32` by sender choice, which is below the protocol maximum (`MAX_SUMMARY_PREVIEW_ITEMS = 64`).

1. If `|previewCandidates| = 1000` and `W = 32`, rank all 1000 by `(expiry_unix_ms, hop_count, item_id_bytes)` and take the first 32 IDs.
2. Re-sort those 32 selected IDs lexicographically by `decodedDigestBytes(item_id)` for `SUMMARY.preview_item_ids` encoding.
3. Derive `SUMMARY.preview_cursor` from the on-wire sorted array: `preview_cursor = last(preview_item_ids)`.
4. Urgency drives which IDs are included; the transmitted order remains canonical lexicographic wire order.

## 7. Expiry semantics and clock skew

1. `expiry_unix_ms` MUST be UTC Unix epoch milliseconds (`uint64`).
2. Receiver MUST evaluate expiry using local UTC clock.
3. `CLOCK_SKEW_TOLERANCE_MS = 30000` (30s) MUST be applied during acceptance decisions.
4. Object is expired when `now_ms + CLOCK_SKEW_TOLERANCE_MS >= expiry_unix_ms`.
5. Expired objects MUST NOT be requested, accepted, or forwarded.

## 8. Deterministic encounter flow

Mandatory high-level sequence:

1. `HELLO`
2. `SUMMARY`
3. `REQUEST`
4. `TRANSFER`
5. `RECEIPT`

`SUMMARY/REQUEST/TRANSFER/RECEIPT` MAY repeat in-cycle for long sessions, but each frame MUST remain independently valid under frame catalog rules.

## 8.1 Deterministic SUMMARY→REQUEST reconciliation (normative)

After receiving a peer `SUMMARY`, an implementation MUST deterministically select a `REQUEST.want` list using the following model and names.

Definitions:

- `candidateItemIDs`: receiver-side candidate item IDs that the receiver believes it might be missing and believes the peer might have.
  Implementations MUST treat `candidateItemIDs` as a set of item IDs; duplicates MUST be ignored.
- `peerPreviewItemIDs`: optional IDs from peer `SUMMARY.preview_item_ids`; these MAY include IDs not in `candidateItemIDs`.
- `localHaveItemIDs`: the receiver's locally-stored item IDs (the set the receiver “has”).

Rules:

 1. Inputs are receiver-side and deterministic:
    - `candidateItemIDs` MUST be derived only from receiver-local state plus the peer-provided Bloom filter; it MUST NOT depend on timing, randomness, or transport metadata.
    - `localHaveItemIDs` is the receiver's local inventory.
 2. Eligible candidate set: define `eligibleItemIDs` as the de-duplicated `candidateItemIDs` with any IDs present in `localHaveItemIDs` removed.
    - `candidateItemIDs` MUST NOT include any item IDs that are present in `localHaveItemIDs`.
  3. Preview-unknown subset: define `previewUnknownItemIDs` as de-duplicated `peerPreviewItemIDs` with any IDs present in `localHaveItemIDs` removed.
  4. Bloom filter constraint: for any `item_id` included in `REQUEST.want`, the peer Bloom filter MUST indicate it *might contain* that `item_id`.
  5. Candidate ordering model:
     - Define `previewEligibleItemIDs` as `previewUnknownItemIDs` filtered by Bloom “might contain”.
     - Define `candidateEligibleItemIDs` as `eligibleItemIDs` filtered by Bloom “might contain”.
     - Build `selectedItemIDs` by taking unique items from `previewEligibleItemIDs` first, then filling remaining capacity from unique items in `candidateEligibleItemIDs`.
  6. Truncation and final ordering: let `N = min(peer.max_want, MAX_WANT_ITEMS)`. After selection under this cap, `REQUEST.want` MUST be bytewise lexicographically sorted by decoded digest bytes of `item_id` (not by hex string order).

Implications:

- `REQUEST.want` MUST be unique by `item_id`.
- If an `item_id` is present in `previewEligibleItemIDs` and is within the preview-priority selection under `N`, it MUST be included in `REQUEST.want`.
- Remaining capacity after preview-priority selection MUST be filled from `candidateEligibleItemIDs` deterministically.

Note: Bloom filters have false positives but no false negatives. A receiver MAY request items the peer does not actually have; this is acceptable.

Note: `candidateItemIDs` MAY be empty; in that case a conforming implementation MAY emit an empty `REQUEST.want` as a valid no-op.

Note: A Bloom filter cannot enumerate or prove the presence of unknown IDs; it can only answer “might contain” for IDs the requester already knows.

## 8.2 Constrained-encounter transfer scheduling (local policy only)

During constrained encounters, nodes MAY prioritize transfer scheduling by local policy (for example: not relay-ingested first, earlier `expiry_unix_ms`, lower `hop_count`, then stable `item_id` tie-break).

This scheduling guidance MUST NOT alter protocol validity, interoperability, or acceptance semantics.

For runtime budgeting/prioritization hook design, see `docs/protocol/encounter-budgeting.md`.

## 8.3 Local-only terminal outcomes (normative)

Encounter terminal outcomes are local runtime outcomes, not wire objects:

1. `clean-end`: encounter ends intentionally after successful progress, completion, or orderly peer shutdown.
2. `failed-end`: encounter ends due to protocol failure, transport/runtime fault, or other non-policy error.
3. `policy-stop`: local policy intentionally stops the encounter attempt even if additional protocol-valid work could continue.

Outcome handling requirements:

1. Implementations MUST record terminal outcome locally for diagnostics/scheduling.
2. Implementations MUST NOT treat terminal outcome labels as additional frame-level semantics.
3. Implementations MAY use terminal outcomes to choose the next local encounter opportunity.

Scheduler mapping note (local-only): `stopReason=policy-stop` maps to terminal outcome `policy-stop`; `stopReason` values `completed`, `no-eligible-items`, `budget-items-exhausted`, `budget-bytes-exhausted`, `encounter-time-exhausted`, and `durable-ratio-cap-reached` map to terminal outcome `clean-end` unless a transport/protocol fault occurred; transport/protocol/runtime faults map to `failed-end`.

## 8.4 Local-only upgrade/downgrade/resume semantics (normative)

Upgrade/downgrade/resume are local scheduler semantics across encounter instances:

1. `upgrade`: local orchestration chooses a higher-capacity next opportunity.
2. `downgrade`: local orchestration chooses a lower-capacity next opportunity.
3. `resume`: local orchestration continues pending work in a later encounter instance.

What MAY carry across encounters:

1. validated local store state (`item_id` inventory, receipt state, durability state),
2. deterministic local scheduler state (ranking/budget diagnostics),
3. local interruption/resume markers for pending units of work.

What MUST be re-done per new encounter instance:

1. HELLO version/identity compatibility checks,
2. SUMMARY exchange and REQUEST construction against the new encounter snapshot,
3. frame-boundary and per-frame validation for the active bearer.

What MUST NOT carry across:

1. partially decoded frame bytes,
2. unvalidated objects,
3. bearer-specific transport/session handles as protocol identity.

Cross-bearer resume/upgrade/downgrade transitions are subject to downgrade-resistance policy in `docs/adr/ADR-0004-multi-bearer-encounter-architecture.md`.

## 8.5 Encounter lifecycle state machine v1 (local-only)

This state machine is local orchestration behavior only. It MUST NOT introduce new on-wire fields.

### 8.5.1 `EncounterContext` (durable) states

Canonical durable states:

1. `idle`: no active encounter instance.
2. `evaluating-opportunity`: evaluating candidate bearer opportunities/capability sets.
3. `active-instance`: one encounter instance is active.
4. `resume-pending`: interruption recorded; next transition decision pending.

Deterministic transitions:

1. `idle -> evaluating-opportunity` on contact visibility or queued pending work.
2. `evaluating-opportunity -> active-instance` on accepted candidate after capability/refusal evaluation.
3. `active-instance -> resume-pending` on interruption marker `contact_lost` or `session_idle_timeout`.
4. `active-instance -> evaluating-opportunity` when instance terminates and pending work remains.
5. `active-instance -> idle` when instance terminates and no pending work remains.
6. `resume-pending -> evaluating-opportunity` when planning next transition (`failover`, `handoff`, `upgrade`, `downgrade`, `resume`).

### 8.5.2 Encounter instance (bearer-scoped) states

Canonical instance states:

1. `initiated`
2. `running`
3. `interrupted`
4. `terminal-clean-end`
5. `terminal-failed-end`
6. `terminal-policy-stop`

Deterministic transitions:

1. `initiated -> running` when attempt enters protocol execution (HELLO/SUMMARY flow).
2. `running -> interrupted` on `contact_lost` or `session_idle_timeout`; the active attempt MUST terminate `failed-end` while emitting the interruption marker.
3. `running -> terminal-*` via the terminal mapping rules in §8.8.
4. `interrupted -> terminal-failed-end` when interruption cannot be recovered in the same instance.

### 8.5.3 `EncounterAttempt` (execution-scoped) states

Canonical attempt states:

1. `pending`
2. `connecting`
3. `handshaking` (HELLO/version/identity checks)
4. `exchanging` (SUMMARY/REQUEST/TRANSFER/RECEIPT cycles)
5. `closing`
6. `terminal-clean-end | terminal-failed-end | terminal-policy-stop`

Deterministic transitions:

1. `pending -> connecting -> handshaking -> exchanging -> closing` for normal completion.
2. Failure in `handshaking` or `exchanging` that is non-policy and unrecoverable in-attempt MUST produce `terminal-failed-end`.
3. Scheduler-directed local stop MUST produce `terminal-policy-stop` only when `stopReason=policy-stop`.
4. Any budget/completion stop reason from scheduler (`completed`, `no-eligible-items`, or budget/time caps) MUST map to `terminal-clean-end` unless a concurrent transport/protocol/runtime fault occurred.

## 8.6 Function lanes: discovery, control, data, resume (local-only)

Function-lane evaluation is attempt-local and deterministic:

1. **discovery**: candidate visibility and contact opportunity updates (`supportsDiscovery`).
2. **control**: HELLO/SUMMARY/REQUEST/RECEIPT control-plane exchange (`supportsControl`).
3. **data**: object/chunk transfer flow (`supportsData`).
4. **resume**: continuation of pending local work markers (`supportsResume` plus valid local resume state).

Rules:

1. `EncounterContext` MUST evaluate lane eligibility using capability-set preflight from `docs/protocol/bearer-capability-model-v1.md` before activating the lane.
2. If a required lane is unsupported, refusal MUST use canonical taxonomy (`capability_mismatch`, `resume_not_supported`, or other ordered refusal from ADR-0004).
3. Discovery downgrade exceptions MUST NOT authorize control or data lanes unless control/data policy checks pass.

## 8.7 Transition intents across encounter instances (local-only)

Transition intents are `EncounterContext` decisions between bearer-scoped encounter instances:

1. `upgrade`: choose a stronger/higher-capacity next bearer opportunity.
2. `downgrade`: choose a weaker/lower-capacity next bearer opportunity that still passes policy minima.
3. `failover`: move to another candidate after interruption or failure.
4. `handoff`: planned switch to another bearer while preserving pending-work continuity.
5. `resume`: continue pending units of work in a newly created encounter instance.

Rules:

1. Every transition intent MUST terminate the current instance before starting the next one.
2. `upgrade`/`downgrade`/`failover`/`handoff`/`resume` MUST be explainable by capability-set and scheduler inputs.
3. `downgrade` and cross-bearer `resume` MUST enforce ADR-0004 downgrade-resistance refusal order.

## 8.8 Deterministic terminal mapping: stopReason/stopClass/refusalReason

### 8.8.1 Scheduler `stopReason` -> terminal outcome and `stopClass`

When scheduler emits canonical `stopReason` (`docs/protocol/encounter-scheduler-v1.md`), terminal mapping MUST be:

- `policy-stop` -> terminal outcome `policy-stop`, `stopClass=policy_stop`
- `completed` -> terminal outcome `clean-end`, `stopClass=completed`
- `no-eligible-items` -> terminal outcome `clean-end`, `stopClass=no_eligible_items`
- `budget-items-exhausted` -> terminal outcome `clean-end`, `stopClass=budget_exhausted`
- `budget-bytes-exhausted` -> terminal outcome `clean-end`, `stopClass=budget_exhausted`
- `encounter-time-exhausted` -> terminal outcome `clean-end`, `stopClass=budget_exhausted`
- `durable-ratio-cap-reached` -> terminal outcome `clean-end`, `stopClass=budget_exhausted`

If a transport/protocol/runtime fault is present for the same attempt, `failed-end` MUST override the clean-end mapping.

Disambiguation (mandatory): scheduler `stopReason=encounter-time-exhausted` is a planning/budget stop and therefore maps to `clean-end`; it MUST NOT be conflated with interruption marker `session_idle_timeout`, which indicates a transport/session fault signal and drives interruption handling.

### 8.8.2 Refusal taxonomy -> terminal outcome

Refusal reasons MUST use ordered canonical taxonomy from capability preflight + ADR-0004:

- capability preflight/time-scope: `time_scope_invalid`, `time_scope_expired`, `time_scope_stale`
- ADR-0004 refusal order: `peer_incompatible`, `capability_mismatch`, `resume_not_supported`, `resume_token_invalid`, `resume_state_missing`, `security_posture_insufficient`, `downgrade_resistance_triggered`
- extension namespace: `x_[a-z0-9_]+`

`time_scope_*` refusal reasons MUST be evaluated first and MUST short-circuit evaluation; ADR-0004 refusal mapping MUST NOT override a `time_scope_*` result.

Deterministic mapping:

1. If refusal reason is one of `peer_incompatible` or `resume_token_invalid`, terminal outcome MUST be `failed-end`.
2. All other refusal reasons MUST map to terminal outcome `policy-stop`.
3. For refusal-mapped `policy-stop`, scheduler-compatible diagnostics MUST emit `stopReason=policy-stop` and `stopClass=policy_stop`.

### 8.8.3 Interruption markers and resume semantics

`contact_lost` and `session_idle_timeout` are local interruption markers, not wire fields and not refusal reasons.

1. On interruption marker, the encounter instance MUST move to `interrupted`; the active attempt MUST terminate `failed-end` and persist resumable pending-work markers.
2. `EncounterContext` MUST re-enter `evaluating-opportunity` and re-run capability-set evaluation (including `timeScope`) before any resume decision.
3. If next candidate passes policy and resume is allowed, context MUST open a new encounter instance and apply transition intent `resume` (or `failover`/`handoff` with resume markers).
4. If no candidate can pass evaluation, context MUST resolve terminal outcome using §8.8.2 refusal mapping.

## 8.9 Canonical EncounterManager responsibilities (model v1)

`EncounterManager` is the local orchestrator model anchored in `EncounterContext`.

Responsibilities:

1. Maintain durable `EncounterContext` and per-instance/attempt lifecycle state.
2. Evaluate capability sets (including deterministic `timeScope` refusal behavior) before lane activation.
3. Invoke scheduler for deterministic ranking, selected prefix, and canonical `stopReason`.
4. Apply terminal mapping rules in §8.8 and persist interruption/resume markers.
5. Decide and emit transition intent (`upgrade`/`downgrade`/`failover`/`handoff`/`resume`) between instances.

Authority boundary (normative):

1. CLAs/Transport Adapters MUST only create and characterize opportunities (capability advertisement + session lifecycle events).
2. CLAs/Transport Adapters MUST NOT make routing, scheduler, ranking, budget, or downgrade-policy authority decisions.
3. Routing MAY propose candidates; scheduler policy remains final authority for selected prefix and stop outcome classification.

## 8.10 Required interaction points (non-normative for future interface/telemetry work)

For future interface and telemetry contract work, implementations SHOULD preserve these explicit interaction points:

1. Scheduler interaction: consume deterministic selected prefix and canonical `stopReason`; derive `stopClass` via §8.8.1 mapping.
2. Capability interaction: evaluate `timeScope` and refusal order exactly as defined in `docs/protocol/bearer-capability-model-v1.md` + ADR-0004.
3. Telemetry interaction (local-only hooks): emit lifecycle transitions, transition intent, terminal outcome, `stopReason`/`stopClass` (when defined), and `refusalReason` (when defined) as separate encounter-orchestration events.

Canonical event keys, 3-layer attribution boundaries, and extension refusal-reason declaration rules are defined in `docs/protocol/multi-bearer-telemetry.md`.

## 9. Transport-neutral correctness constraints

1. Bearers MAY differ in discovery and channel setup.
2. Bearers MUST NOT alter acceptance, rejection, hashing, identity, `expiry_unix_ms`, or hop-count semantics.
3. Bearers MUST NOT inject sender IDs that override envelope-derived author attribution.
4. Linux and iOS implementations MUST share identical RFC 8949 deterministic CBOR and Bloom algorithms.
5. Bearer changes across opportunities MUST remain local orchestration only and MUST NOT modify wire contract semantics.

## 10. Security considerations

- Session admission policy is local, but protocol correctness is global.
- Rate-limiting and abuse controls SHOULD be local policy layers.
- Scoring data MUST remain local-only and MUST NOT be transmitted.
- Clients MUST NOT display unverifiable objects (missing envelope auth fields, invalid signatures, or signing payload mismatch).
