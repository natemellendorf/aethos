# Future Peer Scoring and Propagation Policy Hooks

Status: authoritative policy-boundary guidance; scoring is non-authoritative for correctness.

## 1. Normative boundary

RFC 2119 terms are normative.

Scoring is strictly local-only optimization state.

## 2. Hard correctness separation

1. Scoring MUST NOT affect frame validity decisions.
2. Scoring MUST NOT affect acceptance semantics for valid non-expired objects.
3. Scoring MUST NOT alter hash, identity, `expiry_unix_ms`, or hop-count rules.
4. Absence of scoring MUST preserve full baseline interoperability.

## 3. On-wire prohibition

1. Peer scores MUST NOT be transmitted on-wire.
2. Trust labels or reputation buckets MUST NOT appear in gossip frames.
3. HELLO metadata MAY inform local scoring, but is not an authoritative trust verdict.

## 4. Allowed influence surface

Scoring MAY influence:

- peer connection preference,
- transfer scheduling order,
- replication budget allocation under bandwidth constraints,
- relay-proximity prioritization heuristics.

Scoring outputs MUST remain advisory and MUST NOT violate deterministic protocol rules.

## 4.1 Scheduling-policy boundary

Scoring MAY be used to rank transfer candidates during constrained encounters, but this ranking is local policy only.

Scoring-informed scheduling MUST NOT change wire schema, frame validity, acceptance semantics, or interoperability requirements.

## 5. Cross-platform interoperability

1. Linux/iOS implementations with different scoring models MUST still interoperate.
2. Implementations without scoring MUST remain fully protocol-compliant.
3. Wire behavior MUST remain identical for equivalent valid inputs.

## 6. Security and privacy

- Scores SHOULD be stored as local private state.
- Implementations SHOULD defend against score poisoning with authenticated observations.
- Conservative defaults SHOULD avoid starvation of new/unknown peers.

## 7. Implementation layering

Recommended architecture:

1. Protocol engine (deterministic validation/acceptance).
2. Replication policy layer (budget and ordering decisions).
3. Optional scoring module (local ranking signal only).
