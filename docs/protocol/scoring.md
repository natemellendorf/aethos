# Future Peer Scoring and Propagation Control Architecture

Status: design guidance for future optimization hooks; non-normative for protocol correctness.

## 1. Principle

Peer scoring is allowed as a local optimization layer, but must never alter deterministic protocol correctness.

Hard boundary:

- protocol validity decisions are frame/data-rule based,
- scoring influences preference/priority only,
- scores are never transmitted over the network.

## 2. Available Protocol Inputs

HELLO provides fields intended to support local policy calculations:

- `node_pubkey`
- `node_id`
- `capabilities`
- `propagation_class`

Transfer metadata also offers policy inputs:

- `hop_count`
- `expiry`
- relay-ingest state

## 3. Example Local Scoring Factors

Implementations may evaluate peers using factors such as:

- historical transfer reliability,
- relay/internet connectivity hints,
- observed bandwidth behavior,
- storage reliability (e.g., low rejection/eviction patterns),
- contribution to propagation success.

None of these factors are protocol fields with on-wire authority.

## 4. Policy Influence Surface

Scoring may affect:

- peer connection priority,
- scheduling order for request/transfer budgets,
- replication aggressiveness under constrained bandwidth,
- selection of peers likely to reach relay quickly.

Scoring must not affect:

- frame validity,
- hash/identity validation,
- acceptance semantics for well-formed non-expired objects.

## 5. Propagation Horizon and Scoring Interplay

Propagation horizon determines replication intensity over distance/time.

A scoring-aware policy can combine:

- horizon bucket derived from `hop_count`,
- urgency from `expiry` proximity,
- durability state from relay-ingest confirmation,
- per-peer local score.

Example approach:

1. classify object urgency/horizon,
2. rank candidate peers by local score,
3. allocate limited transfer budget to maximize durability gain.

## 6. Determinism and Interoperability Constraints

To preserve Linux/iOS compatibility:

1. Keep wire frame schema unchanged by scoring features.
2. Keep required field semantics identical regardless of score.
3. Ensure score absence does not break baseline propagation.
4. Ensure fallback behavior is deterministic and standards-compliant.

## 7. Privacy and Security Considerations

- Scores must remain local state and should not be exposed in frames.
- Avoid deriving persistent sensitive labels that could leak user behavior patterns.
- Defend against score poisoning by requiring authenticated/validated observations.
- Keep conservative defaults to prevent starvation of unknown peers.

## 8. Implementation Guidance

Recommended layering:

- **Protocol Engine**: parse/validate frames, execute deterministic sync semantics.
- **Replication Policy Layer**: selects what/when to propagate.
- **Scoring Module (optional)**: produces local ranking inputs consumed by policy.

This separation allows incremental optimization without protocol fragmentation.
